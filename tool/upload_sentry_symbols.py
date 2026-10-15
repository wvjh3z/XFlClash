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
import re
import shutil
import subprocess
import sys
import tempfile

from sentry_elf import ElfError, inspect_elf

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
        env={**os.environ, "SENTRY_LOG_LEVEL": "warn"},
    )
    # `check --json` returns 1 for a PE with a valid debug ID but no embedded
    # unwind/debug sections. Its matching PDB can still be fully usable.
    check_metadata = arguments[:3] == ["debug-files", "check", "--json"]
    if result.returncode and not (check_metadata and result.returncode == 1 and result.stdout.lstrip().startswith("{")):
        raise SymbolError(
            f"sentry-cli {' '.join(arguments[:2])} failed (exit {result.returncode}); "
            "check authentication, project permissions, network and symbol validity"
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
    return {"debug_ids": sorted(ids), "format": info["type"],
            "features": info.get("features", "")}


def fingerprint(path: Path) -> dict:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"name": path.name, "bytes": path.stat().st_size,
            "sha256": digest.hexdigest()}


def audit_windows(cli: str, build_root: Path) -> tuple[list[Path], list[dict]]:
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
        binary, pdb = Path(binary_name), Path(pdb_name)
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
    for target, binary in binaries.items():
        if target == "FlClash" or target.endswith("_plugin"):
            installed = bundle / binary.name
            if not installed.is_file() or fingerprint(installed)["sha256"] != fingerprint(binary)["sha256"]:
                raise SymbolError(f"Bundle does not contain the matching native binary: {target}")
    return artifacts, evidence


def _safe_label(value: object, field: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]{1,100}", value):
        raise SymbolError(f"Invalid native manifest {field}")
    return value


def _native_path(root: Path, value: object) -> Path:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise SymbolError("Native manifest paths must be relative to the build root")
    path = root / value
    if not path.resolve().is_relative_to(root.resolve()):
        raise SymbolError("Native artifact escaped its build root")
    if not path.is_file():
        raise SymbolError("Native manifest references a missing artifact")
    return path


def _audit_native_inventory(build_root: Path, platform: str, entries: list[dict],
                            required: set[tuple[str, str]]) -> None:
    """Check distributed inputs independently of the upload manifest's lists."""
    if platform == "android":
        runtime = build_root / "sentry-native/android/runtime"
        modules, expected = {}, set()
        for directory in sorted(runtime.glob("*/*")):
            abi = directory.name
            if abi not in {"armeabi-v7a", "arm64-v8a", "x86_64"} or not directory.is_dir():
                continue
            if not any((directory / marker).is_file() for marker in ("libapp.so", "libflutter.so")):
                continue
            for target in ("libcore.so", "libclash.so", "librust_api.so"):
                if not (directory / target).is_file():
                    raise SymbolError("APK runtime inventory is missing a mandatory owned module")
                expected.add((target, abi))
            for binary in directory.glob("*.so"):
                checked = _native_path(build_root, binary.relative_to(build_root).as_posix())
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
        source_map = native / f"sentry-native-{native.name.capitalize()}.tsv"
        source_map = _native_path(build_root, source_map.relative_to(build_root).as_posix())
        try:
            rows = source_map.read_text(encoding="utf-8").splitlines()
        except OSError as error:
            raise SymbolError("Linux native audit requires its independent CMake source map") from error
        expected = {("FlClash", architecture): binary,
                    ("librust_api.so", architecture): bundle / "lib/librust_api.so"}
        for row in rows:
            fields = row.split("\t")
            if len(fields) != 2:
                raise SymbolError("Invalid independent CMake source map")
            _safe_label(fields[0], "CMake target")
            source = Path(fields[1])
            if not source.resolve().is_relative_to(native.resolve()):
                raise SymbolError("Independent CMake source escaped its native build root")
            for installed in (bundle / source.name, bundle / "lib" / source.name):
                if installed.is_file():
                    expected[(installed.name, architecture)] = installed
        # A truncated TSV must not turn a locally compiled, matching plugin into
        # an accepted prebuilt gap. Match its actual build intermediate too.
        for installed in (bundle / "lib").glob("*.so"):
            try:
                runtime_info = inspect_elf(installed)
                for source in (native / "plugins").rglob(installed.name):
                    if source.is_symlink() or not source.resolve().is_relative_to(native.resolve()) or not source.is_file():
                        continue
                    info = inspect_elf(source)
                    if (runtime_info["build_id"] and info["build_id"] == runtime_info["build_id"]
                            and info["has_debug_info"] and info["has_debug_line"]):
                        expected[(installed.name, architecture)] = installed
                        break
            except (OSError, ElfError) as error:
                raise SymbolError("Invalid Linux native inventory ELF") from error
        core = bundle / "FlClashCore"
        if core.exists():
            if (core.name, architecture) not in required:
                raise SymbolError("Native manifest omitted the distributed Go core companion")
            expected[(core.name, architecture)] = core
        if not expected.keys() <= required:
            raise SymbolError("Native manifest omitted a distributed CMake or owned native module")
        indexed = {(entry["target"], entry["architecture"]): entry for entry in entries}
        for identity, installed in expected.items():
            declared = _native_path(build_root, indexed[identity]["binary"])
            if declared.resolve() != installed.resolve():
                raise SymbolError("Native artifact does not reference the final Linux bundle")


def audit_elf_native(cli: str, build_root: Path, platform: str) -> tuple[list[Path], list[dict], list[dict]]:
    """Match explicit debug-only ELF companions to the distributed modules.

    The preparation tool supplies final APK entries or installed Linux modules.
    Neither the binaries nor any source/map files are added to the upload list.
    """
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
    static_targets = {"libcore.so", "libclash.so", "librust_api.so"} if platform == "android" else {"FlClash", "librust_api.so"}
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
    return artifacts, evidence, safe_limitations


def collect_companions(cli: str, root: Path, platform: str) -> tuple[list[Path], list[dict]]:
    artifacts, evidence = [], []
    # Flutter's TargetPlatform.darwin differs from our workflow's macos label.
    # getNameForTargetPlatform supplies darwin-{x86_64,arm64}, not macos-*.
    dart_platform = "darwin" if platform == "macos" else platform
    for path in sorted((root / "debug-info").glob(f"app.{dart_platform}-*.symbols")):
        info = check_symbol(cli, path)
        if info["format"] not in ("elf", "dsym"):
            raise SymbolError("Unexpected Dart debug companion format")
        artifacts.append(path)
        evidence.append({"symbols": fingerprint(path), **info})
    if platform == "macos":
        for bundle in sorted((root / "macos/Build/Products/Release").glob("**/*.dSYM")):
            for path in sorted((bundle / "Contents/Resources/DWARF").glob("*")):
                if path.is_file():
                    info = check_symbol(cli, path, "dsym")
                    artifacts.append(path)
                    evidence.append({"symbols": fingerprint(path), **info})
    if platform != "macos" and not artifacts:
        raise SymbolError("No Dart split debug information was generated")
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
        elif args.platform in ("android", "linux"):
            native, native_evidence, limitations = audit_elf_native(cli, args.build_root, args.platform)
            evidence["native_coverage"] = "explicit_manifest_audited"
            evidence["native_limitations"] = limitations
        else:
            native, native_evidence = [], []
        dart, dart_evidence = collect_companions(cli, args.build_root, args.platform)
        files = native + dart
        if not files:
            raise SymbolError("No uploadable debug companions found")
        evidence.update(status="audited", native=native_evidence, companions=dart_evidence)
        if args.audit_only:
            print(f"Sentry offline audit passed: {len(files)} debug companions")
        elif not os.environ.get("SENTRY_AUTH_TOKEN", "").strip():
            if args.platform == "windows":
                raise SymbolError("Windows release requires SENTRY_AUTH_TOKEN for matching native symbols")
            evidence["status"] = "skipped_missing_token"
            print("Sentry upload explicitly skipped: SENTRY_AUTH_TOKEN is missing")
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
                    "--no-zips", "--wait-for", "300", "--require-all",
                ]
                for debug_id in sorted({
                    identifier for item in native_evidence + dart_evidence
                    for identifier in item["debug_ids"]
                }):
                    upload_arguments.extend(["--id", debug_id])
                upload_arguments.append(str(stage))
                run_cli(cli, upload_arguments)
            evidence["status"] = "uploaded_and_processed"
            print(f"Sentry accepted and processed {len(files)} debug companions")
    except (SymbolError, OSError, subprocess.TimeoutExpired) as error:
        evidence["status"] = "failed"
        # Error strings are constructed locally; no raw CLI stderr or tokens.
        evidence["error"] = str(error) if isinstance(error, SymbolError) else type(error).__name__
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
