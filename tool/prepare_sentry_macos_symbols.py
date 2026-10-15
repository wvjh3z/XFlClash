#!/usr/bin/env python3
"""Prepare independent macOS dSYMs against the final app without building it."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import uuid
import zlib

from sentry_macho import MachoError, inspect_macho, is_macho, read_slices

MAX_DEBUG_SECTION = 512 * 1024 * 1024
MAX_DEBUG_PAYLOAD = 1024 * 1024 * 1024


class PreparationError(RuntimeError):
    pass


def safe_label(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", value):
        raise PreparationError("invalid_macos_symbol_label")
    return value


def variants(path: Path):
    try:
        result = inspect_macho(path)["variants"]
    except (MachoError, OSError) as error:
        raise PreparationError("invalid_macos_symbol_input") from error
    if any(item["architecture"] not in {"x86_64", "arm64"} or not item["uuid"] for item in result):
        raise PreparationError("missing_macos_uuid_or_architecture")
    return result


def _go_debug_slice(source: Path, item: dict) -> bytes:
    """Copy only final-linked DWARF into MH_DSYM; no executable bytes survive."""
    if item["endian"] != "<" or item["architecture"] not in {"x86_64", "arm64"}:
        raise PreparationError("unsupported_go_macho_slice")
    sections = [entry for entry in item["sections"]
                if entry["segment"] == "__DWARF" and entry["has_contents"]]
    if not item["has_debug_info"] or not item["has_debug_line"] or not sections:
        raise PreparationError("go_macho_dwarf_unavailable")
    text = next((segment for segment in item["segments"] if segment["name"] == "__TEXT"), None)
    if text is None:
        raise PreparationError("go_macho_text_base_unavailable")
    command_size = 24 + 72 + 72 + len(sections) * 80
    data_offset = (32 + command_size + 7) & ~7
    cursor, payload, section_commands = data_offset, bytearray(), []
    with source.open("rb") as stream:
        for section in sections:
            alignment = min(section["align"], 16)
            aligned = (cursor + (1 << alignment) - 1) & ~((1 << alignment) - 1)
            payload.extend(b"\0" * (aligned - cursor))
            stream.seek(section["offset"])
            contents = stream.read(section["size"])
            if len(contents) != section["size"]:
                raise PreparationError("truncated_go_macho_dwarf")
            name = section["name"]
            # Go's default GNU-style compressed Mach-O DWARF is not recognized
            # by symbolic/Sentry as usable line information. Materialize it.
            if name.startswith("__zdebug_"):
                if contents[:4] != b"ZLIB" or len(contents) < 12:
                    raise PreparationError("invalid_compressed_go_dwarf")
                expected = struct.unpack(">Q", contents[4:12])[0]
                if not 0 < expected <= MAX_DEBUG_SECTION:
                    raise PreparationError("oversize_compressed_go_dwarf")
                try:
                    decoder = zlib.decompressobj()
                    contents = decoder.decompress(contents[12:], expected + 1)
                except zlib.error as error:
                    raise PreparationError("invalid_compressed_go_dwarf") from error
                if len(contents) != expected or not decoder.eof or decoder.unused_data:
                    raise PreparationError("invalid_compressed_go_dwarf")
                name = name.replace("__zdebug_", "__debug_", 1)
            if len(contents) > MAX_DEBUG_SECTION or len(payload) + len(contents) > MAX_DEBUG_PAYLOAD:
                raise PreparationError("oversize_go_debug_payload")
            payload.extend(contents)
            section_commands.append(struct.pack("<16s16sQQIIIIIIII",
                name.encode("ascii"), b"__DWARF", 0, len(contents), aligned,
                alignment, 0, 0, 0x02000000, 0, 0, 0))
            cursor = aligned + len(contents)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, item["cpu_type"], item["cpu_subtype"],
                         10, 3, command_size, 0, 0)
    identifier = struct.pack("<II", 0x1B, 24) + uuid.UUID(item["uuid"]).bytes
    text_command = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__TEXT",
                               text["vmaddr"], text["vmsize"], 0, 0, 0, 0, 0, 0)
    dwarf_command = struct.pack("<II16sQQQQiiII", 0x19, 72 + len(sections) * 80,
                                b"__DWARF", 0, len(payload), data_offset, len(payload), 0, 0,
                                len(sections), 0) + b"".join(section_commands)
    commands = header + identifier + text_command + dwarf_command
    return commands + b"\0" * (data_offset - len(commands)) + payload


def extract_go_dsym(source: Path, destination: Path) -> Path:
    """Go internal linking has embedded DWARF, not dsymutil's OSO object map."""
    source = source.resolve()
    safe_label(source.name)
    if not destination.name.endswith(".dSYM") or destination.is_symlink():
        raise PreparationError("invalid_go_dsym_destination")
    slices = read_slices(source)
    if not slices or any(item["filetype"] != 2 for item in slices):
        raise PreparationError("go_dsym_requires_executable_macho")
    content = [_go_debug_slice(source, item) for item in slices]
    if len(content) == 1:
        data = content[0]
    else:
        cursor = (8 + 20 * len(slices) + 4095) & ~4095
        offsets = []
        for item, raw in zip(slices, content):
            offsets.append((item["cpu_type"], item["cpu_subtype"], cursor, len(raw), 12))
            cursor = (cursor + len(raw) + 4095) & ~4095
        data = bytearray(struct.pack(">II", 0xCAFEBABE, len(slices)))
        for values in offsets:
            data.extend(struct.pack(">iiIII", *values))
        for values, raw in zip(offsets, content):
            data.extend(b"\0" * (values[2] - len(data)))
            data.extend(raw)
        data = bytes(data)
    if destination.exists():
        shutil.rmtree(destination)
    dwarf = destination / "Contents/Resources/DWARF" / source.name
    dwarf.parent.mkdir(parents=True)
    dwarf.write_bytes(data)
    metadata = {"CFBundleIdentifier": "com.apple.xcode.dsym." + source.name,
                "CFBundlePackageType": "dSYM", "CFBundleVersion": "1"}
    with (destination / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(metadata, stream)
    original = {(item["architecture"], item["uuid"]) for item in variants(source)}
    copied = variants(dwarf)
    if original != {(item["architecture"], item["uuid"]) for item in copied} or any(
            item["filetype"] != 10 or item["has_executable_text"]
            or not item["has_debug_info"] or not item["has_debug_line"] for item in copied):
        raise PreparationError("go_dsym_validation_failed")
    return dwarf


def macho_inventory(app: Path):
    result = []
    seen = set()
    for path in sorted(app.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        resolved = path.resolve()
        if not resolved.is_relative_to(app.resolve()):
            raise PreparationError("app_macho_escaped_bundle")
        if resolved not in seen and is_macho(path):
            result.append(resolved)
            seen.add(resolved)
    return result


def dwarf_files(root: Path):
    return [path for bundle in root.rglob("*.dSYM") if bundle.is_dir()
            for path in (bundle / "Contents/Resources/DWARF").glob("*") if path.is_file()]


def contains_rust_debug(dwarfdump: str, path: Path) -> bool:
    # Read only until a Rust compilation unit is proved, never emit source paths.
    process = subprocess.Popen([dwarfdump, "--debug-info", str(path)], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
    total, found = 0, False
    try:
        for line in process.stdout:
            total += len(line)
            if b"DW_AT_language" in line and b"DW_LANG_Rust" in line:
                found = True
                break
            if total > 32 * 1024 * 1024:
                break
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait()
    return found


def resolve_apple_tool(name: str) -> str:
    explicit = shutil.which(name)
    if explicit:
        return explicit
    result = subprocess.run(["xcrun", "--find", name], capture_output=True, text=True)
    if result.returncode or not Path(result.stdout.strip()).is_file():
        raise PreparationError("apple_debug_tool_unavailable")
    return result.stdout.strip()


class Preparer:
    def __init__(self, build_root: Path, configuration="Release", app=None,
                 dsymutil=None, dwarfdump=None):
        self.root = build_root.resolve()
        self.products = self.root / "macos/Build/Products" / configuration
        apps = [path for path in self.products.glob("*.app") if path.is_dir()]
        if app is None:
            if len(apps) != 1:
                raise PreparationError("one_final_macos_app_required")
            app = apps[0]
        self.app = app.resolve()
        if not self.app.is_relative_to(self.products.resolve()) or not self.app.is_dir():
            raise PreparationError("final_macos_app_outside_products")
        self.output = self.root / "sentry-native/macos"
        if self.output.is_symlink() or not self.output.resolve().is_relative_to(self.root):
            raise PreparationError("unsafe_macos_symbol_output")
        if self.output.exists():
            shutil.rmtree(self.output)
        self.output.mkdir(parents=True)
        self.dsymutil, self.dwarfdump = dsymutil, dwarfdump
        self.artifacts, self.limitations, self.required = [], [], []

    def limitation(self, target, architecture, source, reason):
        self.limitations.append(dict(target=target, architecture=architecture, source=source, reason=reason))

    def prepare(self):
        try:
            metadata = json.loads((self.root / "macos/sentry-native-owned.json").read_text())
            records = metadata["products"]
            if metadata.get("schema_version") != 1 or not isinstance(records, list):
                raise ValueError()
            owned = {safe_label(item["product"]): safe_label(item["target"]) for item in records}
            with (self.app / "Contents/Info.plist").open("rb") as stream:
                executable = plistlib.load(stream)["CFBundleExecutable"]
        except (OSError, KeyError, ValueError, TypeError) as error:
            raise PreparationError("macos_owned_or_bundle_metadata_missing") from error
        runner = (self.app / "Contents/MacOS" / executable).resolve()
        inventory = macho_inventory(self.app)
        if runner not in inventory:
            raise PreparationError("macos_runner_macho_missing")
        candidates = dwarf_files(self.products)
        candidates += dwarf_files(self.root.parent / "libclash/macos")
        candidate_variants = {path: variants(path) for path in candidates}
        present_products, targets, has_rust, has_core, has_dart = set(), set(), False, False, False
        for binary in inventory:
            framework = next((part for part in binary.relative_to(self.app).parts if part.endswith(".framework")), None)
            source = "runner" if binary == runner else "prebuilt"
            target = "runner" if binary == runner else safe_label(binary.name)
            if framework:
                present_products.add(framework)
                if framework in owned:
                    source = "pods"
            if binary.name == "rust_api" and framework == "rust_api.framework":
                source, has_rust = "rust", True
            elif binary.name == "FlClashCore":
                source, has_core = "go", True
            slices = variants(binary)
            if framework == "App.framework" and binary.name == "App":
                has_dart = True
                for item in slices:
                    self.limitation(target, item["architecture"], "dart", "split_debug_info_managed_separately")
                continue
            if target in targets:
                raise PreparationError("duplicate_macos_module_target")
            targets.add(target)
            required = source != "prebuilt"
            pairs = {(item["architecture"], item["uuid"]) for item in slices}
            matching = [path for path, items in candidate_variants.items()
                        if pairs <= {(item["architecture"], item["uuid"]) for item in items}
                        and all(item["filetype"] == 10 and item["has_debug_info"]
                                and item["has_debug_line"] and not item["has_executable_text"]
                                for item in items)]
            if not matching and required and source != "go":
                # Native Xcode binaries retain an OSO map to the source objects.
                tool = self.dsymutil or resolve_apple_tool("dsymutil")
                destination = self.output / (target + ".dSYM")
                completed = subprocess.run([tool, str(binary), "-o", str(destination)],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                generated = list((destination / "Contents/Resources/DWARF").glob("*"))
                if not completed.returncode and len(generated) == 1:
                    items = variants(generated[0])
                    if pairs <= {(item["architecture"], item["uuid"]) for item in items} and all(
                            item["filetype"] == 10 and item["has_debug_info"]
                            and item["has_debug_line"] and not item["has_executable_text"] for item in items):
                        matching = generated
            if not matching:
                if required:
                    raise PreparationError("required_macos_matching_dsym_unavailable")
                for item in slices:
                    self.limitation(target, item["architecture"], source, "prebuilt_debug_companion_unavailable")
                continue
            original = matching[0]
            destination = self.output / (target + ".dSYM/Contents/Resources/DWARF") / target
            destination.parent.mkdir(parents=True, exist_ok=True)
            if original.resolve() != destination.resolve():
                shutil.copyfile(original, destination)
            if source == "rust" and not contains_rust_debug(self.dwarfdump or resolve_apple_tool("dwarfdump"), destination):
                raise PreparationError("rust_framework_missing_rust_compilation_units")
            for item in slices:
                entry = dict(target=target, architecture=item["architecture"], source=source,
                             binary=binary.relative_to(self.root).as_posix(),
                             debug_file=destination.relative_to(self.root).as_posix())
                self.artifacts.append(entry)
                if required:
                    self.required.append(dict(target=target, architecture=item["architecture"]))
                if source == "go":
                    self.limitation(target, item["architecture"], source, "separate_process_no_sentry_sdk")
        if not has_rust or not has_core or not has_dart or not owned.keys() <= present_products:
            raise PreparationError("required_macos_native_product_missing")
        result = dict(schema_version=1, platform="macos", app=self.app.relative_to(self.root).as_posix(),
                      artifacts=self.artifacts, required=self.required, limitations=self.limitations)
        manifest = self.output / "manifest.json"
        manifest.write_text(json.dumps(result, indent=2) + "\n")
        return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path, default=Path("build"))
    parser.add_argument("--app", type=Path)
    parser.add_argument("--configuration", choices=["Release", "Profile"], default="Release")
    parser.add_argument("--dsymutil")
    parser.add_argument("--dwarfdump")
    parser.add_argument("--extract-go", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.extract_go:
            if args.output is None:
                raise PreparationError("go_dsym_output_required")
            extract_go_dsym(args.extract_go, args.output)
        else:
            Preparer(args.build_root, args.configuration, args.app, args.dsymutil, args.dwarfdump).prepare()
        print("macos_debug_companions_prepared")
        return 0
    except PreparationError as error:
        code = str(error)
        print(code if re.fullmatch(r"[a-z_]+", code) else "macos_symbol_preparation_failed", file=sys.stderr)
        return 1
    except (OSError, ValueError, MachoError):
        print("macos_symbol_preparation_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
