#!/usr/bin/env python3
"""Audit and upload explicit debug companions, never source or release binaries.

Windows builds must supply the CMake-generated Release manifest and matching
PDBs. --audit-only is entirely offline and does not need an auth token. CI keeps
the resulting JSON as the build's symbol evidence, without absolute paths.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

from sentry_upload_confirmation import UploadError, cli_failure, confirm_symbol_inventory

from sentry_elf import ElfError, inspect_elf
from sentry_android_prefab import SENTRY_ANDROID_TARGETS
from sentry_linux_inventory import LinuxInventoryError, collect_linux_inventory
from sentry_macho import MachoError, inspect_macho, is_macho, static_archive_architectures
from sentry_macos_inventory import (
    InventoryError, LINKER_ONLY_LIMITATION, SOURCE_LINE_LIMITATION, load_inventory,
    required_source_targets, source_line_limitations,
)
from prepare_sentry_macos_symbols import contains_rust_debug, resolve_apple_tool

CLI_VERSION = "2.58.4"
PROJECTS = {"brand_a": "omofly", "brand_b": "daishu"}
REQUIRED_WINDOWS_TARGETS = {"FlClash", "flutter_inappwebview_windows_plugin"}


class SymbolError(RuntimeError):
    pass


def run_cli(cli: str, arguments: list[str]) -> str:
    # No token on the command line; never relay verbose diagnostics, response
    # bodies, configuration, or absolute paths into public CI output.
    result = subprocess.run(
        [cli, *arguments], capture_output=True, text=True, encoding="utf-8",
        errors="replace", timeout=900,
        env={**os.environ, "SENTRY_LOG_LEVEL": "warn", "SENTRY_URL": "https://us.sentry.io/"},
    )
    # `check --json` returns 1 for a PE with a valid debug ID but no embedded
    # unwind/debug sections. Its matching PDB can still be fully usable.
    check_metadata = arguments[:3] == ["debug-files", "check", "--json"]
    if result.returncode and not (check_metadata and result.returncode == 1 and result.stdout.lstrip().startswith("{")):
        if arguments[:2] == ["debug-files", "upload"]:
            raise cli_failure(result.returncode, result.stdout, result.stderr)
        raise SymbolError(
            f"sentry-cli {' '.join(arguments[:2])} failed (exit {result.returncode})"
        )
    return result.stdout


def check_symbol(cli: str, path: Path, expected_type: str | None = None,
                 *, require_usable: bool = True) -> dict:
    if not path.is_file():
        raise SymbolError(f"Missing debug artifact: {path.name}")
    try:
        info = json.loads(run_cli(cli, ["debug-files", "check", "--json", str(path)]))
    except json.JSONDecodeError as error:
        raise SymbolError("sentry-cli returned invalid symbol metadata") from error
    ids = {v["debug_id"].lower() for v in info.get("variants", [])
           if re.fullmatch(r"[a-fA-F0-9-]+", v.get("debug_id", ""))
           and v["debug_id"].replace("-", "").strip("0")}
    if not ids or (require_usable and expected_type != "pe" and not info.get("is_usable")):
        raise SymbolError(f"Unusable debug information: {path.name}")
    if expected_type and info.get("type") != expected_type:
        raise SymbolError(f"Unexpected symbol format: {path.name}")
    architectures = {item["arch"] for item in info.get("variants", [])
                     if re.fullmatch(r"[A-Za-z0-9_+-]+", item.get("arch", ""))}
    return {"debug_ids": sorted(ids), "architectures": sorted(architectures), "format": info["type"],
            "features": info.get("features", "")}


def fingerprint(path: Path) -> dict:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"name": path.name, "bytes": path.stat().st_size,
            "sha256": digest.hexdigest()}


def audit_windows(cli: str, build_root: Path) -> tuple[list[Path], list[dict]]:
    build_root = build_root.resolve()
    manifests = list(build_root.glob("**/sentry-symbols/Release/targets.tsv"))
    if len(manifests) != 1:
        raise SymbolError("Expected one fresh Windows Release target manifest")
    artifacts, evidence, targets, binaries = [], [], set(), {}
    for row in manifests[0].read_text(encoding="utf-8").splitlines():
        fields = row.split("\t")
        if len(fields) != 3 or not re.fullmatch(r"[A-Za-z0-9_.+-]+", fields[0]):
            raise SymbolError("Invalid Windows target manifest")
        target, binary_name, pdb_name = fields
        if target in targets:
            raise SymbolError("Duplicate Windows symbol target")
        targets.add(target)
        binary, pdb = Path(binary_name).resolve(), Path(pdb_name).resolve()
        binaries[target] = binary
        for artifact in (binary, pdb):
            if not artifact.resolve().is_relative_to(build_root.resolve()):
                raise SymbolError("Windows symbol artifact escaped its build root")
        if pdb.suffix.lower() != ".pdb" or binary.suffix.lower() not in (".exe", ".dll"):
            raise SymbolError("Windows manifest contains a non-native artifact")
        binary_info = check_symbol(cli, binary, "pe")
        pdb_info = check_symbol(cli, pdb, "pdb")
        if binary_info["debug_ids"] != pdb_info["debug_ids"]:
            raise SymbolError(f"Binary/PDB debug identifier mismatch: {target}")
        if "debug" not in pdb_info["features"].split(", "):
            raise SymbolError(f"PDB is missing line debug information: {target}")
        artifacts.append(pdb)
        evidence.append({"target": target, "binary": fingerprint(binary),
                         "symbols": fingerprint(pdb), **pdb_info})
    if not REQUIRED_WINDOWS_TARGETS <= targets:
        raise SymbolError("Windows symbols must cover the runner and tutorial plugin")
    bundle = binaries["FlClash"].parent
    distributed_plugins = {path.stem for path in bundle.glob("*_plugin.dll") if path.is_file()}
    if not distributed_plugins <= targets:
        raise SymbolError("Windows manifest omitted a distributed native plugin")
    if (bundle / "rust_api.dll").is_file() and "rust_api" not in targets:
        raise SymbolError("Windows manifest omitted the distributed Rust PDB")
    for target, binary in binaries.items():
        if target == "FlClash" or target == "rust_api" or target.endswith("_plugin") or (bundle / binary.name).is_file():
            installed = bundle / binary.name
            if not installed.is_file() or fingerprint(installed)["sha256"] != fingerprint(binary)["sha256"]:
                raise SymbolError(f"Bundle does not contain the matching native binary: {target}")
    return artifacts, evidence


def _windows_native_limits(build_root: Path, evidence: list[dict]) -> list[dict]:
    build_root = build_root.resolve()
    manifest = next(build_root.glob("**/sentry-symbols/Release/targets.tsv"))
    rows = [row.split("\t") for row in manifest.read_text(encoding="utf-8").splitlines()]
    bundle = Path(next(row[1] for row in rows if row[0] == "FlClash")).resolve().parent
    architectures = next(item.get("architectures", []) for item in evidence if item["target"] == "FlClash") or ["unknown"]
    owned = {item["binary"]["name"] for item in evidence}
    limitations = []
    for path in bundle.iterdir():
        if not path.is_file():
            continue
        if path.name in {"FlClashCore.exe", "FlClashHelperService.exe"}:
            source, reason = "go", "separate_process_no_sentry_sdk"
        elif path.suffix.lower() == ".dll" and path.name not in owned:
            source, reason = "prebuilt", "external_debug_companion_unavailable"
        else:
            continue
        for architecture in architectures:
            limitations.append({"target": _safe_label(path.name, "Windows target"),
                                "architecture": _safe_label(architecture, "Windows architecture"),
                                "source": source, "reason": reason})
    return limitations


def _safe_label(value: object, field: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]{1,100}", value):
        raise SymbolError(f"Invalid native manifest {field}")
    return value


def _native_path(root: Path, value: object) -> Path:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise SymbolError("Native manifest paths must be relative to the build root")
    root = root.resolve()
    path = root / value
    if not path.resolve().is_relative_to(root):
        raise SymbolError("Native artifact escaped its build root")
    if not path.is_file():
        raise SymbolError("Native manifest references a missing artifact")
    return path


def _native_relative_path(root: Path, path: Path) -> str:
    """Compare real paths before converting macOS aliases/Windows short names.

    Resolving only the root leaves manifest absolute paths under /var (or a
    Windows 8.3 directory) lexically outside its /private/var/long-name spelling.
    Resolving both sides also keeps symlinks that escape the build root rejected.
    """
    root, path = root.resolve(), path.resolve()
    if not path.is_relative_to(root):
        raise SymbolError("Native artifact escaped its build root")
    return path.relative_to(root).as_posix()


def _audit_native_inventory(build_root: Path, platform: str, entries: list[dict],
                            required: set[tuple[str, str]]) -> None:
    """Check distributed inputs independently of the upload manifest's lists."""
    build_root = build_root.resolve()
    if platform == "android":
        runtime = build_root / "sentry-native/android/runtime"
        modules, expected = {}, set()
        for directory in sorted(runtime.glob("*/*")):
            abi = directory.name
            if abi not in {"armeabi-v7a", "arm64-v8a", "x86_64"} or not directory.is_dir():
                continue
            if not any((directory / marker).is_file() for marker in ("libapp.so", "libflutter.so")):
                continue
            for target in ("libcore.so", "libclash.so"):
                if not (directory / target).is_file():
                    raise SymbolError("APK runtime inventory is missing a mandatory owned module")
                expected.add((target, abi))
            # rust_api is not an Android Flutter plugin in this project. It is
            # mandatory only when a future/package-specific build ships it.
            for target in {"librust_api.so"} | SENTRY_ANDROID_TARGETS:
                if (directory / target).is_file():
                    expected.add((target, abi))
            for binary in directory.glob("*.so"):
                checked = _native_path(build_root, _native_relative_path(build_root, binary))
                modules.setdefault((binary.name, abi), []).append(checked)
        if not expected:
            raise SymbolError("Android native audit requires final APK runtime inventory")
        if not expected <= required:
            raise SymbolError("Native manifest omitted a distributed Android ABI or mandatory owned module")
        for identity in expected:
            if len({fingerprint(path)["sha256"] for path in modules[identity]}) != 1:
                raise SymbolError("Final APKs contain conflicting owned native modules")
        for entry in entries:
            identity = (entry["target"], entry["architecture"])
            binary = _native_path(build_root, entry["binary"])
            if binary.resolve() not in {path.resolve() for path in modules.get(identity, [])}:
                raise SymbolError("Native artifact does not reference the final APK runtime inventory")
        return

    for runner in (entry for entry in entries if entry["target"] == "FlClash"):
        architecture = runner["architecture"]
        binary = _native_path(build_root, runner["binary"])
        native, bundle = binary.parent.parent, binary.parent
        if (bundle.name != "bundle" or native.name not in {"release", "profile"}
                or native.parent != build_root / "linux" / architecture):
            raise SymbolError("Linux native audit requires the final configured bundle")
        try:
            inventory = collect_linux_inventory(build_root, architecture, native.name)
        except LinuxInventoryError as error:
            if str(error) == "local_plugin_source_manifest_missing":
                raise SymbolError("Native manifest omitted a distributed CMake or owned native module") from error
            raise SymbolError("Invalid Linux native inventory: " + str(error)) from error
        expected = {(name, architecture): inventory["modules"][name] for name in inventory["required"]}
        if "FlClashCore" in inventory["modules"] and ("FlClashCore", architecture) not in required:
            raise SymbolError("Native manifest omitted the distributed Go core companion")
        if not expected.keys() <= required:
            raise SymbolError("Native manifest omitted a distributed CMake or owned native module")
        for entry in (item for item in entries if item["architecture"] == architecture):
            copies = inventory["modules"].get(entry["target"], [])
            actual_paths = {path.resolve() for path in copies}
            declared = _native_path(build_root, entry["binary"])
            if declared.resolve() not in actual_paths:
                raise SymbolError("Native artifact does not reference the final Linux bundle")
            declared_copies = entry.get("binary_copies", [entry["binary"]])
            if not isinstance(declared_copies, list) or not declared_copies:
                raise SymbolError("Linux native artifact must enumerate its runtime copies")
            copied_paths = [_native_path(build_root, value).resolve() for value in declared_copies]
            if len(copied_paths) != len(set(copied_paths)) or set(copied_paths) != actual_paths:
                raise SymbolError("Linux native artifact omitted or changed a runtime copy")


def audit_elf_native(cli: str, build_root: Path, platform: str) -> tuple[list[Path], list[dict], list[dict]]:
    """Match explicit debug-only ELF companions to the distributed modules.

    The preparation tool supplies final APK entries or installed Linux modules.
    Neither the binaries nor any source/map files are added to the upload list.
    """
    build_root = build_root.resolve()
    manifest_path = build_root / "sentry-native" / platform / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SymbolError("Missing or invalid Android/Linux native symbol manifest") from error
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1 or manifest.get("platform") != platform:
        raise SymbolError("Unexpected native manifest schema or platform")
    entries, limitations = manifest.get("artifacts"), manifest.get("limitations", [])
    required_entries = manifest.get("required")
    if not isinstance(entries, list) or not entries or not isinstance(limitations, list):
        raise SymbolError("Native manifest must enumerate its debug companions and limitations")
    if not isinstance(required_entries, list) or not required_entries:
        raise SymbolError("Native manifest must enumerate required module coverage")
    architectures = ({"armeabi-v7a": "arm", "arm64-v8a": "aarch64", "x86_64": "x86_64"}
                     if platform == "android" else {"x64": "x86_64", "arm64": "aarch64"})
    artifacts, evidence, seen = [], [], set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise SymbolError("Invalid native artifact record")
        target = _safe_label(entry.get("target"), "target")
        architecture = _safe_label(entry.get("architecture"), "architecture")
        source = _safe_label(entry.get("source"), "source")
        identity = (target, architecture)
        if identity in seen or architecture not in architectures:
            raise SymbolError("Duplicate or unsupported native artifact architecture")
        seen.add(identity)
        binary = _native_path(build_root, entry.get("binary"))
        debug_file = _native_path(build_root, entry.get("debug_file"))
        if binary.name != target:
            raise SymbolError("Native target does not match its distributed binary name")
        if debug_file.suffix != ".debug" or binary.resolve() == debug_file.resolve():
            raise SymbolError("Native uploads require a separate .debug companion")
        try:
            binary_elf, debug_elf = inspect_elf(binary), inspect_elf(debug_file)
        except (OSError, ElfError) as error:
            raise SymbolError("Invalid native ELF binary or companion") from error
        if not binary_elf["build_id"] or binary_elf["build_id"] != debug_elf["build_id"]:
            raise SymbolError(f"ELF build identifier mismatch: {target}")
        if any(item["architecture"] != architectures[architecture] for item in (binary_elf, debug_elf)):
            raise SymbolError(f"ELF architecture mismatch: {target}")
        if debug_elf["has_executable_text"]:
            raise SymbolError(f"Native debug companion still contains executable code: {target}")
        if not debug_elf["has_debug_info"] or not debug_elf["has_debug_line"]:
            raise SymbolError(f"Native debug companion lacks DWARF line information: {target}")
        binary_info = check_symbol(cli, binary, "elf", require_usable=False)
        debug_info = check_symbol(cli, debug_file, "elf")
        if binary_info["debug_ids"] != debug_info["debug_ids"]:
            raise SymbolError(f"Binary/ELF debug identifier mismatch: {target}")
        if "debug" not in debug_info["features"].split(", "):
            raise SymbolError(f"ELF companion is missing line debug information: {target}")
        if "unwind" in binary_info["features"].split(", ") and "unwind" not in debug_info["features"].split(", "):
            raise SymbolError(f"ELF companion is missing the binary's unwind information: {target}")
        artifacts.append(debug_file)
        evidence.append({"target": target, "architecture": architecture, "source": source,
                         "build_id": binary_elf["build_id"], "binary": fingerprint(binary),
                         "symbols": fingerprint(debug_file), **debug_info})
        if platform == "linux" and "binary_copies" in entry:
            copies = entry["binary_copies"]
            if not isinstance(copies, list) or not copies:
                raise SymbolError("Linux native artifact must enumerate its runtime copies")
            evidence[-1]["binary_copies"] = [fingerprint(_native_path(build_root, value)) for value in copies]
    required = set()
    for entry in required_entries:
        if not isinstance(entry, dict):
            raise SymbolError("Invalid required native module record")
        identity = (_safe_label(entry.get("target"), "target"),
                    _safe_label(entry.get("architecture"), "architecture"))
        if identity in required or identity[1] not in architectures:
            raise SymbolError("Duplicate or unsupported required native module")
        required.add(identity)
    if not required <= seen:
        raise SymbolError("Native manifest omitted a required debug companion")
    static_targets = {"libcore.so", "libclash.so"} if platform == "android" else {"FlClash", "librust_api.so"}
    for architecture in {architecture for _, architecture in seen}:
        if not {(target, architecture) for target in static_targets} <= required:
            raise SymbolError("Native manifest omitted mandatory owned module coverage")
    _audit_native_inventory(build_root, platform, entries, required)
    safe_limitations = []
    for entry in limitations:
        if not isinstance(entry, dict):
            raise SymbolError("Invalid native coverage limitation")
        safe_limitations.append({key: _safe_label(entry.get(key), key)
                                 for key in ("target", "architecture", "source", "reason")})
        if (platform == "android" and entry["target"] in SENTRY_ANDROID_TARGETS
                and (entry["target"], entry["architecture"]) in required):
            raise SymbolError("Required Sentry prefab coverage cannot also be a limitation")
    return artifacts, evidence, safe_limitations


def _macho_variants(path: Path) -> dict[str, dict]:
    try:
        variants = inspect_macho(path)["variants"]
    except (MachoError, OSError) as error:
        raise SymbolError("Invalid Mach-O runtime or debug companion") from error
    if any(not item["uuid"] or item["architecture"] not in {"x86_64", "arm64"} for item in variants):
        raise SymbolError("Missing Mach-O UUID or unsupported release architecture")
    return {item["architecture"]: item for item in variants}


def audit_macos(cli: str, build_root: Path) -> tuple[list[Path], list[dict], list[dict]]:
    """Audit every owned final .app module against a separate DWARF dSYM."""
    build_root = build_root.resolve()
    try:
        manifest = json.loads((build_root / "sentry-native/macos/manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SymbolError("macOS release requires its native symbol manifest") from error
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1 or manifest.get("platform") != "macos":
        raise SymbolError("Invalid macOS symbol manifest")
    app_value = manifest.get("app")
    if not isinstance(app_value, str) or Path(app_value).is_absolute():
        raise SymbolError("macOS app path must be relative to the build root")
    app = build_root / app_value
    products = build_root / "macos/Build/Products/Release"
    if (not app.resolve().is_relative_to(products.resolve()) or not app.is_dir() or app.suffix != ".app"
            or app.parent.resolve() != products.resolve()):
        raise SymbolError("macOS symbol audit requires the final Release app bundle")
    candidates = [path.resolve() for path in products.glob("*.app") if path.is_dir()]
    if candidates != [app.resolve()]:
        raise SymbolError("macOS symbol audit requires one unambiguous Release app")
    try:
        owned = load_inventory(build_root, app)
    except InventoryError as error:
        raise SymbolError("macOS dependency inventory/build receipt is missing or does not match the final app") from error
    owned_products = {item["product"] for item in owned["products"]}
    owned_sources = {item["product"]: item["source"] for item in owned["products"]}
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            app_metadata = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SymbolError("macOS Release app is missing valid executable metadata") from error
    executable = app_metadata.get("CFBundleExecutable") if isinstance(app_metadata, dict) else None
    if (not isinstance(executable, str) or not executable or len(executable) > 200
            or executable in {".", ".."} or any(character in executable for character in ("/", "\\", "\0"))):
        raise SymbolError("Invalid macOS app executable filename")
    runner = (app / "Contents/MacOS" / executable).resolve()
    inventory, physical_paths = {}, set()
    for path in app.rglob("*"):
        if not path.is_file() or path.resolve() in physical_paths:
            continue
        if not is_macho(path):
            continue
        actual = path.resolve()
        if not actual.is_relative_to(app.resolve()):
            raise SymbolError("Mach-O module escaped its final app bundle")
        physical_paths.add(actual)
        target = "runner" if actual == runner else _safe_label(path.name, "Mach-O target")
        product_names = {parent.name for parent in path.parents if parent.suffix == ".framework"}
        product_names.add(path.name)
        expected_source = ("runner" if target == "runner" else "rust" if target == "rust_api"
                           else "go" if target == "FlClashCore" else next(
                               (owned_sources[name] for name in product_names if name in owned_sources), "prebuilt"))
        for architecture, info in _macho_variants(path).items():
            identity = (target, architecture)
            if identity in inventory or info["filetype"] not in (2, 6, 8):
                raise SymbolError("Duplicate or non-runtime Mach-O inside the app bundle")
            inventory[identity] = {"binary": actual, "info": info,
                                   "owned": bool(product_names & owned_products)
                                            or target in {"runner", "rust_api", "FlClashCore"},
                                   "source": expected_source,
                                   "dart": "App.framework" in product_names}
    if not any(target == "runner" for target, _ in inventory):
        raise SymbolError("macOS app executable is missing from its native inventory")
    if not any(target == "rust_api" for target, _ in inventory):
        raise SymbolError("macOS app is missing its required Rust framework")
    entries, required_entries, limitations = manifest.get("artifacts"), manifest.get("required"), manifest.get("limitations", [])
    if not isinstance(entries, list) or not entries or not isinstance(required_entries, list) or not required_entries or not isinstance(limitations, list):
        raise SymbolError("macOS manifest must enumerate companions, requirements and limitations")
    artifacts, evidence, seen = [], [], set()
    rust_dwarfdump = None
    for entry in entries:
        if not isinstance(entry, dict):
            raise SymbolError("Invalid macOS companion record")
        target = _safe_label(entry.get("target"), "target")
        architecture = _safe_label(entry.get("architecture"), "architecture")
        source = _safe_label(entry.get("source"), "source")
        identity = (target, architecture)
        if identity in seen or identity not in inventory:
            raise SymbolError("Duplicate or undistributed macOS companion record")
        seen.add(identity)
        if source != inventory[identity]["source"]:
            raise SymbolError("macOS companion source does not match the dependency inventory")
        binary, debug = (_native_path(build_root, entry.get(key)) for key in ("binary", "debug_file"))
        if binary.resolve() != inventory[identity]["binary"]:
            raise SymbolError("macOS companion does not reference the final app module")
        if (debug.resolve().is_relative_to(app.resolve()) or debug.parent.name != "DWARF"
                or debug.parent.parent.name != "Resources" or debug.parent.parent.parent.name != "Contents"
                or debug.parent.parent.parent.parent.suffix != ".dSYM"):
            raise SymbolError("macOS uploads require a separate dSYM DWARF companion")
        debug_variants = _macho_variants(debug)
        if architecture not in debug_variants:
            raise SymbolError("dSYM is missing a distributed Mach-O architecture")
        info = debug_variants[architecture]
        if info["uuid"] != inventory[identity]["info"]["uuid"]:
            raise SymbolError("Final Mach-O and dSYM UUID mismatch")
        if any(item["filetype"] != 10 or item["has_executable_text"] for item in debug_variants.values()):
            raise SymbolError("dSYM companion contains a runtime Mach-O or executable code")
        if not info["has_debug_info"] or not info["has_debug_line"]:
            raise SymbolError("dSYM is missing DWARF line information")
        if source == "rust":
            # An independent/reused audit must prove Rust language CUs in
            # every distributed slice, even when the companion is universal.
            # UUID and generic C/Swift line tables alone are insufficient.
            try:
                rust_dwarfdump = rust_dwarfdump or resolve_apple_tool("dwarfdump")
                has_rust = contains_rust_debug(rust_dwarfdump, debug, architecture=architecture)
            except Exception:
                # Native tools can include private paths or source text in
                # exceptions. The bounded scanner owns its process cleanup.
                raise SymbolError("macos_rust_debug_verification_failed") from None
            if not has_rust:
                raise SymbolError("macos_rust_slice_missing_rust_compilation_units")
        binary_info = check_symbol(cli, binary, "dsym", require_usable=False)
        debug_info = check_symbol(cli, debug, "dsym")
        if info["uuid"] not in binary_info["debug_ids"] or info["uuid"] not in debug_info["debug_ids"] or "debug" not in debug_info["features"].split(", "):
            raise SymbolError("Sentry cannot match the Mach-O and usable dSYM identifiers")
        artifacts.append(debug)
        evidence.append({"target": target, "architecture": architecture, "source": source,
                         "binary": fingerprint(binary), "symbols": fingerprint(debug),
                         "format": "dsym", "features": debug_info["features"], "debug_ids": [info["uuid"]]})
    required = set()
    for item in required_entries:
        if not isinstance(item, dict):
            raise SymbolError("Invalid required macOS module record")
        identity = (_safe_label(item.get("target"), "target"), _safe_label(item.get("architecture"), "architecture"))
        if identity in required:
            raise SymbolError("Duplicate required macOS module")
        required.add(identity)
    if not required <= seen:
        raise SymbolError("macOS manifest omitted a required dSYM companion")
    if any(not set(item["hosts"]) <= {target for target, _ in required}
           for item in required_source_targets(owned["source_targets"])):
        raise SymbolError("macOS source package omitted its static host dSYM")
    # Independently use final-UUID-matched local runtime link maps so removing
    # both a required record and its artifact cannot hide a source module.
    for identity, runtime in inventory.items():
        if runtime["dart"]:
            continue
        target, architecture = identity
        if not runtime["owned"]:
            for candidate in products.rglob(runtime["binary"].name):
                if (not candidate.is_file() or candidate.resolve().is_relative_to(app.resolve())
                        or not is_macho(candidate)):
                    continue
                try:
                    if static_archive_architectures(candidate) is not None:
                        continue
                except MachoError as error:
                    raise SymbolError("Invalid Mach-O build candidate") from error
                info = _macho_variants(candidate).get(architecture)
                if (info and info["uuid"] == runtime["info"]["uuid"]
                        and info["filetype"] in {2, 6, 8} and info["has_oso_symbols"]):
                    runtime["owned"] = True
                    break
        if runtime["owned"] and identity not in required:
            raise SymbolError("macOS manifest omitted a locally compiled or required app module")
    safe_limitations = []
    limited = set()
    host_architectures = {}
    for target, architecture in inventory:
        host_architectures.setdefault(target, set()).add(architecture)
    try:
        expected_source_limits = {
            (item["package"], item["target"], item["host"], item["architecture"]): item["reason"]
            for item in source_line_limitations(owned["source_targets"], host_architectures)
        }
    except InventoryError:
        raise SymbolError("macOS source package host architecture is unavailable") from None
    source_limits = set()
    expected_static_vendor_limits = {
        (item["target"], architecture)
        for item in owned["binary_targets"] for host in set(item["hosts"]) - set(item["dynamic_hosts"])
        for architecture in host_architectures[host]
    }
    static_vendor_limits = set()
    for item in limitations:
        if not isinstance(item, dict):
            raise SymbolError("Invalid macOS coverage limitation")
        safe = {key: _safe_label(item.get(key), key) for key in ("target", "architecture", "source", "reason")}
        if safe["reason"] in {SOURCE_LINE_LIMITATION, LINKER_ONLY_LIMITATION}:
            safe.update({key: _safe_label(item.get(key), key) for key in ("package", "host")})
            identity = (safe["package"], safe["target"], safe["host"], safe["architecture"])
            if (safe["source"] != "spm" or expected_source_limits.get(identity) != safe["reason"]
                    or identity in source_limits):
                raise SymbolError("Invalid or duplicate macOS source target coverage limitation")
            source_limits.add(identity)
            # A target-to-host evidence limit can never replace a runtime
            # module's required dSYM or its explicit prebuilt-module limit.
        elif safe["reason"] == "static_binary_package_debug_coverage_unverified":
            identity = (safe["target"], safe["architecture"])
            if safe["source"] != "prebuilt" or identity not in expected_static_vendor_limits:
                raise SymbolError("Invalid macOS static binary coverage limitation")
            # The vendor target and runtime host can have the same name.
            # This scope never substitutes for a missing runtime companion.
            static_vendor_limits.add(identity)
        else:
            identity = (safe["target"], safe["architecture"])
            runtime = inventory.get(identity)
            if runtime is None:
                raise SymbolError("Invalid macOS runtime coverage limitation")
            if safe["reason"] in {"prebuilt_debug_companion_unavailable", "external_debug_companion_unavailable"}:
                valid = (safe["source"] == runtime["source"] == "prebuilt"
                         and not runtime["owned"] and identity not in seen and not runtime["dart"])
            elif safe["reason"] == "split_debug_info_managed_separately":
                valid = safe["source"] == "dart" and runtime["dart"]
            elif safe["reason"] == "separate_process_no_sentry_sdk":
                valid = safe["source"] == runtime["source"] == "go" and safe["target"] == "FlClashCore"
            else:
                valid = False
            if not valid:
                raise SymbolError("Invalid macOS runtime coverage limitation")
            limited.add(identity)
        safe_limitations.append(safe)
    if source_limits != set(expected_source_limits):
        raise SymbolError("macOS source package omitted its target line coverage limitation")
    if not inventory.keys() <= seen | limited:
        raise SymbolError("macOS manifest omitted a distributed module or its explicit limitation")
    if any(inventory.get((item["target"], item["architecture"]), {}).get("owned")
           and item["source"] == "prebuilt"
           and not (item["reason"] == "static_binary_package_debug_coverage_unverified"
                    and (item["target"], item["architecture"]) in expected_static_vendor_limits)
           for item in safe_limitations):
        raise SymbolError("Required macOS source coverage cannot also be a limitation")
    for item in owned["binary_targets"]:
        for host in set(item["hosts"]) - set(item["dynamic_hosts"]):
            if any((item["target"], architecture) not in static_vendor_limits
                   for target, architecture in inventory if target == host):
                raise SymbolError("macOS static binary package omitted its explicit coverage limitation")
    return list(dict.fromkeys(artifacts)), evidence, safe_limitations


def _dart_runtime_modules(root: Path, platform: str) -> dict[str, list[Path]]:
    root = root.resolve()
    result = {}
    if platform == "android":
        names = {"armeabi-v7a": "arm", "arm64-v8a": "arm64", "x86_64": "x64"}
        for directory in sorted((root / "sentry-native/android/runtime").glob("*/*")):
            if directory.name not in names or not any((directory / name).is_file() for name in ("libapp.so", "libflutter.so")):
                continue
            path = _native_path(root, _native_relative_path(root, directory / "libapp.so"))
            result.setdefault(names[directory.name], []).append(path)
    elif platform == "windows":
        manifests = list((root / "windows").glob("**/sentry-symbols/Release/targets.tsv"))
        if len(manifests) != 1:
            raise SymbolError("Dart audit requires one final Windows runner manifest")
        rows = [row.split("\t") for row in manifests[0].read_text(encoding="utf-8").splitlines()]
        runners = [Path(row[1]) for row in rows if len(row) == 3 and row[0] == "FlClash"]
        if len(runners) != 1:
            raise SymbolError("Dart audit requires one final Windows runner")
        runtime = runners[0].parent / "data/app.so"
        runtime = _native_path(root, _native_relative_path(root, runtime))
        try:
            architecture = {"x86_64": "x64", "aarch64": "arm64"}[inspect_elf(runtime)["architecture"]]
        except (ElfError, KeyError, OSError) as error:
            raise SymbolError("Invalid final Windows Dart AOT library") from error
        result[architecture] = [runtime]
    else:
        try:
            manifest = json.loads((root / "sentry-native" / platform / "manifest.json").read_text(encoding="utf-8"))
            if platform == "linux":
                for entry in manifest["artifacts"]:
                    if entry["target"] == "FlClash":
                        binary = _native_path(root, entry["binary"]).parent / "lib/libapp.so"
                        path = _native_path(root, _native_relative_path(root, binary))
                        result.setdefault(entry["architecture"], []).append(path)
            else:
                app = root / manifest["app"]
                candidates = {path.resolve() for path in (app / "Contents/Frameworks/App.framework").rglob("App") if path.is_file()}
                if len(candidates) != 1:
                    raise SymbolError("Dart audit requires one final macOS App.framework AOT module")
                binary = _native_path(root, _native_relative_path(root, candidates.pop()))
                for architecture in _macho_variants(binary):
                    result[architecture] = [binary]
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise SymbolError("Dart audit requires the final platform AOT inventory") from error
    if not result:
        raise SymbolError("Dart audit found no distributed AOT modules")
    return result


def _dart_companion_shape(path: Path, platform: str, suffix: str) -> tuple[str, str]:
    expected = {"x64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "arm": "arm"}.get(suffix)
    if expected is None:
        raise SymbolError("Unsupported Dart split companion architecture")
    try:
        with path.open("rb") as stream:
            elf = stream.read(4) == b"\x7fELF"
        if elf:
            if platform == "macos":
                raise SymbolError("macOS Dart split symbols require the pinned macOS Flutter Mach-O snapshot build")
            info = inspect_elf(path)
            if info["has_executable_text"]:
                raise SymbolError("Dart split companion contains executable code")
            if not info["has_debug_info"] or not info["has_debug_line"] or not info["build_id"]:
                raise SymbolError("Dart split companion lacks identified DWARF line information")
            if info["architecture"] != expected:
                raise SymbolError("Dart split companion filename does not match its architecture")
            return "elf", info["build_id"]
        if platform != "macos":
            raise SymbolError("Dart split companion is not a debug-only ELF file")
        variants = _macho_variants(path)
        actual = "arm64" if suffix == "arm64" else suffix
        if set(variants) != {actual}:
            raise SymbolError("Dart split companion filename does not match its architecture")
        info = variants[actual]
        if info["filetype"] != 10 or info["has_executable_text"]:
            raise SymbolError("Dart split companion contains a runtime Mach-O or executable code")
        if not info["has_debug_info"] or not info["has_debug_line"]:
            raise SymbolError("Dart split companion lacks DWARF line information")
        return "dsym", info["uuid"]
    except (ElfError, OSError) as error:
        raise SymbolError("Invalid Dart debug-only companion") from error


def collect_companions(cli: str, root: Path, platform: str,
                       expected_architectures: set[str] | None = None) -> tuple[list[Path], list[dict]]:
    root = root.resolve()
    artifacts, evidence = [], []
    # Flutter's TargetPlatform.darwin differs from our workflow's macos label.
    # getNameForTargetPlatform supplies darwin-{x86_64,arm64}, not macos-*.
    dart_platform = "darwin" if platform == "macos" else platform
    runtimes = _dart_runtime_modules(root, platform)
    for path in sorted((root / "debug-info").glob(f"app.{dart_platform}-*.symbols")):
        path = _native_path(root, _native_relative_path(root, path))
        try:
            info = check_symbol(cli, path)
        except SymbolError as error:
            if platform == "macos":
                raise SymbolError("macOS Dart split symbols have no usable identifier; use the pinned macOS Flutter Mach-O snapshot build") from error
            raise
        if info["format"] not in ("elf", "dsym"):
            raise SymbolError("Unexpected Dart debug companion format")
        if "debug" not in info["features"].split(", "):
            raise SymbolError("Dart split companion is missing line debug information")
        suffix = path.name.removeprefix(f"app.{dart_platform}-").removesuffix(".symbols")
        if suffix not in runtimes:
            raise SymbolError("Dart split companion has no matching distributed AOT architecture")
        companion_format, companion_id = _dart_companion_shape(path, platform, suffix)
        expected_architecture = "x86_64" if suffix in {"x64", "x86_64"} else suffix
        actual_architectures = info.get("architectures", [])
        if actual_architectures and any(
                architecture != expected_architecture
                and not (expected_architecture == "arm" and architecture.startswith("armv"))
                for architecture in actual_architectures):
            raise SymbolError("Dart split companion filename does not match its architecture")
        binaries = []
        for runtime in runtimes[suffix]:
            if platform == "macos":
                architecture = "arm64" if suffix == "arm64" else suffix
                expected_id = _macho_variants(runtime)[architecture]["uuid"]
                runtime_info = check_symbol(cli, runtime, "dsym", require_usable=False)
                if set(info["debug_ids"]) != {expected_id} or expected_id not in runtime_info["debug_ids"]:
                    raise SymbolError("macOS Dart split identifiers do not match final App.framework; use a supported matching snapshot build")
            else:
                try:
                    actual = inspect_elf(runtime)
                except (ElfError, OSError) as error:
                    raise SymbolError("Invalid final Dart AOT ELF module") from error
                expected_architecture = {"x64": "x86_64", "arm64": "aarch64", "arm": "arm"}[suffix]
                if actual["architecture"] != expected_architecture:
                    raise SymbolError("Final Dart AOT library does not match its distributed architecture")
                if companion_format != "elf" or companion_id != actual["build_id"]:
                    raise SymbolError("Dart AOT and split companion build identifier mismatch")
                runtime_info = check_symbol(cli, runtime, "elf", require_usable=False)
                if info["debug_ids"] != runtime_info["debug_ids"]:
                    raise SymbolError("Dart AOT and split companion debug identifier mismatch")
            binaries.append(fingerprint(runtime))
        artifacts.append(path)
        evidence.append({"symbols": fingerprint(path), "binaries": binaries, **info})
    if not artifacts:
        raise SymbolError("No Dart split debug information was generated")
    if expected_architectures or runtimes:
        found = {path.name.removeprefix(f"app.{dart_platform}-").removesuffix(".symbols") for path in artifacts}
        if not set(runtimes) <= found or (expected_architectures and not expected_architectures <= found):
            raise SymbolError("Dart split debug information is missing a distributed architecture")
    return artifacts, evidence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("windows", "android", "linux", "macos"), required=True)
    parser.add_argument("--flavor", choices=PROJECTS, required=True)
    parser.add_argument("--build-root", type=Path, default=Path("build"))
    parser.add_argument("--evidence", type=Path, default=Path("build/sentry-symbols-evidence.json"))
    parser.add_argument("--sentry-cli", default="sentry-cli")
    parser.add_argument("--product-version")
    parser.add_argument("--build-number")
    parser.add_argument("--source-revision")
    parser.add_argument("--audit-only", action="store_true")
    args = parser.parse_args(argv)
    evidence = {"schema_version": 1, "platform": args.platform, "flavor": args.flavor,
                "cli_version": CLI_VERSION, "source_upload": False,
                "release_binary_upload": False, "status": "not_started"}
    try:
        for key, value, pattern in (
            ("product_version", args.product_version, r"[0-9]+\.[0-9]+\.[0-9]+(?:[.+-][A-Za-z0-9.-]+)?"),
            ("build_number", args.build_number, r"[0-9]+"),
            ("source_revision", args.source_revision, r"[a-fA-F0-9]{7,64}"),
        ):
            if value is not None:
                if not re.fullmatch(pattern, value):
                    raise SymbolError(f"Invalid safe build metadata: {key}")
                evidence[key] = value
        cli = shutil.which(args.sentry_cli)
        if not cli:
            raise SymbolError(f"Install @sentry/cli@{CLI_VERSION} before symbol audit")
        version = run_cli(cli, ["--version"]).strip()
        if version != f"sentry-cli {CLI_VERSION}":
            raise SymbolError(f"Expected sentry-cli {CLI_VERSION}")
        if args.platform == "windows":
            native, native_evidence = audit_windows(cli, args.build_root / "windows")
            evidence["native_coverage"] = "explicit_manifest_audited"
            evidence["native_limitations"] = _windows_native_limits(args.build_root / "windows", native_evidence)
        elif args.platform in ("android", "linux"):
            native, native_evidence, limitations = audit_elf_native(cli, args.build_root, args.platform)
            evidence["native_coverage"] = "explicit_manifest_audited"
            evidence["native_limitations"] = limitations
        elif args.platform == "macos":
            native, native_evidence, limitations = audit_macos(cli, args.build_root)
            evidence["native_coverage"] = "explicit_manifest_audited"
            evidence["native_limitations"] = limitations
        else:
            native, native_evidence = [], []
        if args.platform == "macos":
            dart_architectures = {entry["architecture"] for entry in native_evidence if entry.get("target") == "runner"}
        elif args.platform == "android":
            dart_architectures = {{"armeabi-v7a": "arm", "arm64-v8a": "arm64", "x86_64": "x64"}[entry["architecture"]]
                                  for entry in native_evidence}
        elif args.platform == "linux":
            dart_architectures = {entry["architecture"] for entry in native_evidence if entry.get("target") == "FlClash"}
        else:
            dart_architectures = {{"x86_64": "x64", "x86": "x64", "arm64": "arm64"}.get(architecture, architecture)
                                  for entry in native_evidence if entry.get("target") == "FlClash"
                                  for architecture in entry.get("architectures", [])}
        dart, dart_evidence = collect_companions(cli, args.build_root, args.platform, dart_architectures)
        files = list(dict.fromkeys(native + dart))
        if not files:
            raise SymbolError("No uploadable debug companions found")
        evidence.update(status="audited", native=native_evidence, companions=dart_evidence)
        if args.audit_only:
            print(f"Sentry offline audit passed: {len(files)} debug companions")
        elif not os.environ.get("SENTRY_AUTH_TOKEN", "").strip():
            raise SymbolError("Release symbol upload requires SENTRY_AUTH_TOKEN; use --audit-only for offline diagnostics")
        else:
            # Stage only allowlisted companions. No recursive repository/build
            # scan, binary, flavor, env.json, DSN, or include-sources option.
            with tempfile.TemporaryDirectory(prefix="xflclash-sentry-") as temporary:
                stage = Path(temporary)
                for index, path in enumerate(files):
                    destination = stage / str(index) / path.name
                    destination.parent.mkdir()
                    shutil.copyfile(path, destination)
                upload_arguments = [
                    "debug-files", "upload", "--org", "ka-chiu-lee",
                    "--project", PROJECTS[args.flavor], "--no-sources",
                    "--no-zips", "--wait-for", "300",
                ]
                # CLI 2.58.4 compares --require-all IDs with newly uploaded
                # files, so already processed files incorrectly fail a retry.
                # The audits above require every local companion and matching
                # ID; keep the exact ID filter and propagate every CLI failure.
                for debug_id in sorted({
                    identifier for item in native_evidence + dart_evidence
                    for identifier in item["debug_ids"]
                }):
                    upload_arguments.extend(["--id", debug_id])
                upload_arguments.append(str(stage))
                upload_started = time.monotonic()
                try:
                    output = run_cli(cli, upload_arguments)
                except UploadError as error:
                    evidence["upload"] = error.diagnostic
                    # Only a processing-stage failure may be reconciled by GET.
                    # Auth, transport, invalid input and unknown failures remain fatal.
                    if error.category != "processing_incomplete":
                        raise
                except subprocess.TimeoutExpired:
                    error = UploadError("cli_timeout", phase="upload")
                    evidence["upload"] = error.diagnostic
                    raise error from None
                else:
                    evidence["upload"] = {"phase": "upload", "category": "cli_success", "exit_code": 0}
                    lines = {line.strip() for line in output.splitlines()}
                    if not lines.intersection({"> Nothing to upload, all files are on the server",
                                               "> File processing complete:"}):
                        raise SymbolError("Sentry CLI did not confirm server symbol processing completion")
                finally:
                    if "upload" in evidence:
                        evidence["upload"]["elapsed_seconds"] = round(time.monotonic() - upload_started, 3)
                evidence["confirmation"] = {}
                confirm_symbol_inventory(
                    PROJECTS[args.flavor], native_evidence + dart_evidence,
                    os.environ["SENTRY_AUTH_TOKEN"], evidence["confirmation"], emit=print,
                )
            evidence["status"] = "uploaded_and_processed"
            print(f"Sentry accepted and processed {len(files)} debug companions")
    except (SymbolError, UploadError, OSError, subprocess.TimeoutExpired) as error:
        evidence["status"] = "failed"
        # Error strings are constructed locally; no raw CLI stderr or tokens.
        evidence["error"] = str(error) if isinstance(error, (SymbolError, UploadError)) else type(error).__name__
        print(f"Sentry symbols failed: {evidence['error']}", file=sys.stderr)
        return_code = 1
    else:
        return_code = 0
    finally:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
