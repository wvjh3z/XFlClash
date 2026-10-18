#!/usr/bin/env python3
"""Prepare independent macOS dSYMs against the final app without building it."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import struct
import subprocess
import signal
import sys
import tempfile
import time
import uuid
import zlib

from owned_process_cleanup import CleanupError, cleanup_owned_group, safe_cleanup

from sentry_macho import MachoError, inspect_macho, is_macho, read_slices, static_archive_architectures
from sentry_macos_inventory import (
    InventoryError, load_inventory, required_source_targets, source_line_limitations,
)

MAX_DEBUG_SECTION = 512 * 1024 * 1024
MAX_DEBUG_PAYLOAD = 1024 * 1024 * 1024
DSYMUTIL_TIMEOUT = 300
RUST_DWARFDUMP_TIMEOUT = 60
MAX_RUST_DEBUG_OUTPUT = 32 * 1024 * 1024
MAX_DWARF_ATTRIBUTE_LINE = 65536
PREPARATION_TIMEOUT = 600
MAX_PREPARATION_MODULES = 128
MAX_COMPANION_INPUTS = 4096
MAX_SOURCE_CANDIDATES = 4096
MAX_GENERATED_DSYMS = 64
MAX_MODULE_GENERATIONS = 4
RUST_LANGUAGE_ATTRIBUTE = re.compile(
    rb"\s*(?:0x[0-9a-fA-F]+:\s*)?DW_AT_language"
    rb"(?:\s+\[DW_FORM_[A-Za-z0-9_]+\])?\s*"
    rb"\(\s*DW_LANG_Rust\s*\)\s*"
)


class PreparationError(RuntimeError):
    def __init__(self, code, *, diagnostic=None):
        super().__init__(code)
        self.diagnostic = diagnostic


DIAGNOSTIC_PHASES = frozenset({
    "prepare", "inventory", "companions", "products", "normalize", "rust_debug", "manifest", "report",
    "launch", "selector", "read", "eof", "wait", "cleanup", "complete",
})
EXCEPTION_KINDS = frozenset({
    "none", "preparation", "file_not_found", "permission", "os_error", "value_error", "type_error",
    "timeout", "runtime_error", "other",
})
MAX_RETAINED_DIAGNOSTICS = 16


def exception_kind(error):
    # Never serialize class names or exception messages supplied by a tool.
    for category, label in ((PreparationError, "preparation"), (subprocess.TimeoutExpired, "timeout"),
                            (FileNotFoundError, "file_not_found"), (PermissionError, "permission"),
                            (OSError, "os_error"), (ValueError, "value_error"), (TypeError, "type_error"),
                            (RuntimeError, "runtime_error")):
        if isinstance(error, category):
            return label
    return "other"


def safe_diagnostic(value):
    """Project only fixed enum values, booleans and bounded numbers."""
    result = {}
    for key in ("phase", "exception_kind", "cleanup_exception_kind", "cleanup"):
        allowed = (DIAGNOSTIC_PHASES if key == "phase" else
                   {"not_started", "complete", "failed"} if key == "cleanup" else EXCEPTION_KINDS)
        if value.get(key) in allowed:
            result[key] = value[key]
    for key in ("process_started", "eof", "reaped", "pipe_closed"):
        if type(value.get(key)) is bool:
            result[key] = value[key]
    for key in ("returncode", "output_bytes"):
        number = value.get(key)
        if key in value and (number is None or (type(number) is int and -2147483648 <= number <= MAX_RUST_DEBUG_OUTPUT + 65536)):
            result[key] = number
    if isinstance(value.get("cleanup_details"), dict):
        result["cleanup_details"] = safe_cleanup(value["cleanup_details"])
    if value.get("architecture") in {"arm64", "x86_64"}:
        result["architecture"] = value["architecture"]
    return result


def retain_failure_diagnostic(code, diagnostics):
    """Optional bounded CI summaries survive TemporaryDirectory fixture cleanup."""
    configured = os.environ.get("SENTRY_MACOS_DIAGNOSTICS_DIR")
    if not configured:
        return
    try:
        destination = Path(configured)
        if destination.is_symlink():
            return
        destination.mkdir(parents=True, exist_ok=True)
        slots = [destination / f"failure-{index:02d}.json" for index in range(MAX_RETAINED_DIAGNOSTICS)]
        # Fixed names cap output even when many intentional negative fixtures run.
        slot = next((path for path in slots if not path.exists() and not path.is_symlink()), None)
        if slot is None:
            candidates = [path for path in slots if path.is_file() and not path.is_symlink()]
            if not candidates:
                return
            slot = min(candidates, key=lambda path: path.stat().st_mtime_ns)
        value = dict(schema_version=1, failure=code if code in SAFE_PREPARATION_CODES else
                     "macos_symbol_preparation_failed", diagnostics=[safe_diagnostic(item) for item in diagnostics[:MAX_PREPARATION_MODULES]])
        # Open without following a substituted symlink; no raw report is copied.
        descriptor = os.open(slot, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        # Ordinary missing-symbol/UUID negative cases cannot overwrite these
        # fixed slots for unexpected exceptions or reader lifecycle failures.
        reserved = {"macos_symbol_preparation_failed": "unexpected.json",
                    "macos_rust_dwarfdump_failed": "reader-lifecycle.json",
                    "macos_debug_process_termination_timeout": "reader-termination.json"}.get(value["failure"])
        if reserved is not None:
            descriptor = os.open(destination / reserved,
                                 os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
            with os.fdopen(descriptor, "w") as stream:
                json.dump(value, stream, indent=2, sort_keys=True)
                stream.write("\n")
    except (OSError, ValueError, TypeError):
        # Failure to retain optional CI evidence must not replace the real error.
        pass


SAFE_PREPARATION_CODES = frozenset({
    "app_macho_escaped_bundle", "apple_debug_tool_lookup_timeout", "apple_debug_tool_unavailable",
    "duplicate_macos_module_target", "final_macos_app_outside_products", "go_dsym_output_required",
    "go_dsym_requires_executable_macho", "go_dsym_validation_failed", "go_macho_dwarf_unavailable",
    "go_macho_text_base_unavailable", "invalid_compressed_go_dwarf", "invalid_go_dsym_destination",
    "invalid_macos_symbol_input", "invalid_macos_symbol_label", "macos_debug_process_termination_timeout",
    "macos_dsymutil_timeout", "macos_owned_or_bundle_metadata_missing", "macos_runner_macho_missing",
    "macos_rust_dwarfdump_failed", "macos_rust_dwarfdump_incomplete", "macos_rust_dwarfdump_output_limit",
    "macos_rust_dwarfdump_timeout", "missing_macos_uuid_or_architecture", "one_final_macos_app_required",
    "oversize_compressed_go_dwarf", "oversize_go_debug_payload", "required_macos_matching_dsym_unavailable",
    "required_macos_native_product_missing", "rust_framework_missing_rust_compilation_units",
    "source_macos_package_host_architecture_missing", "static_macos_package_host_dsym_missing",
    "truncated_go_macho_dwarf", "unsafe_macos_symbol_output", "unsupported_go_macho_slice",
    "unsupported_rust_debug_architecture", "macos_symbol_preparation_limit_exceeded",
    "macos_symbol_preparation_timeout", "unsafe_macos_symbol_preparation_report",
    "macos_source_image_escaped_products", "invalid_macos_source_image", "truncated_macos_debug_slice",
    "macos_symbol_preparation_failed", "macos_symbol_preparation_report_failed",
})


def preparation_code(error):
    return str(error) if isinstance(error, PreparationError) and str(error) in SAFE_PREPARATION_CODES else "macos_symbol_preparation_failed"


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
    for bundle in root.rglob("*.dSYM"):
        if bundle.is_dir():
            for path in (bundle / "Contents/Resources/DWARF").glob("*"):
                if path.is_file():
                    yield path


def stop_debug_process(process):
    if os.name == "posix":
        return cleanup_owned_group(process)
    if process.poll() is None:
        try:
            process.terminate()
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                raise PreparationError("macos_debug_process_termination_timeout") from None
    return {"outcome": "complete", "reaped": process.returncode is not None, "errors": []}


def run_dsymutil(tool: str, binary: Path, destination: Path, *, timeout=DSYMUTIL_TIMEOUT):
    try:
        return subprocess.run([tool, str(binary), "-o", str(destination)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise PreparationError("macos_dsymutil_timeout") from None


def is_rust_language_attribute(line: bytes) -> bool:
    # Match the property itself, never a source/producer/name string that
    # happens to contain its spelling. This is LLVM/Apple dwarfdump syntax.
    return RUST_LANGUAGE_ATTRIBUTE.fullmatch(line) is not None


def launch_debug_reader(command):
    return subprocess.Popen(command, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, start_new_session=os.name == "posix")


def read_debug_pipe(descriptor, size):
    return os.read(descriptor, size)


def contains_rust_debug(dwarfdump: str, path: Path, *, architecture=None, timeout=RUST_DWARFDUMP_TIMEOUT,
                        diagnostic=None) -> bool:
    # Read only until a Rust compilation unit is proved, never emit source paths.
    if architecture is not None and architecture not in {"arm64", "x86_64"}:
        raise PreparationError("unsupported_rust_debug_architecture")
    command = [dwarfdump, "--debug-info"] + (["--arch=" + architecture] if architecture else []) + [str(path)]
    state = dict(phase="launch", exception_kind="none", cleanup_exception_kind="none", returncode=None,
                 output_bytes=0, process_started=False, eof=False, reaped=False, pipe_closed=False,
                 cleanup="not_started")
    if architecture is not None:
        state["architecture"] = architecture
    process, failure = None, None
    total, found, pending, dropping_line = 0, False, b"", False
    deadline = time.monotonic() + timeout
    try:
        process = launch_debug_reader(command)
        state["process_started"] = True
        state["phase"] = "selector"
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                state["phase"] = "read"
                if time.monotonic() >= deadline:
                    raise PreparationError("macos_rust_dwarfdump_timeout")
                for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                    chunk = read_debug_pipe(key.fileobj.fileno(), min(65536, MAX_RUST_DEBUG_OUTPUT - total + 1))
                    if not chunk:
                        state.update(phase="eof", eof=True)
                        selector.unregister(key.fileobj)
                        continue
                    remaining = MAX_RUST_DEBUG_OUTPUT - total
                    total += len(chunk)
                    state["output_bytes"] = total
                    captured = chunk[:remaining]
                    if dropping_line:
                        _, separator, captured = captured.partition(b"\n")
                        if not separator:
                            if total > MAX_RUST_DEBUG_OUTPUT:
                                raise PreparationError("macos_rust_dwarfdump_output_limit")
                            continue
                        dropping_line = False
                    pending += captured
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        if len(line) <= MAX_DWARF_ATTRIBUTE_LINE and is_rust_language_attribute(line):
                            found = True
                            break
                    if found:
                        break
                    if total > MAX_RUST_DEBUG_OUTPUT:
                        raise PreparationError("macos_rust_dwarfdump_output_limit")
                    if len(pending) > MAX_DWARF_ATTRIBUTE_LINE:
                        pending = b""
                        dropping_line = True
                if found:
                    break
            if not found:
                # EOF and child exit are separate events. Explicitly reap after
                # EOF instead of selecting an empty set or racing poll().
                state["phase"] = "wait"
                try:
                    process.wait(timeout=max(.001, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    raise PreparationError("macos_rust_dwarfdump_timeout") from None
                if process.returncode != 0:
                    raise PreparationError("macos_rust_dwarfdump_incomplete")
                found = not dropping_line and is_rust_language_attribute(pending)
        state["phase"] = "complete"
    except Exception as error:
        state["exception_kind"] = exception_kind(error)
        failure = error if isinstance(error, PreparationError) else PreparationError("macos_rust_dwarfdump_failed")
    finally:
        if process is not None:
            try:
                state["cleanup_details"] = stop_debug_process(process)
                state["cleanup"] = "complete"
            except Exception as error:
                if isinstance(error, CleanupError):
                    state["cleanup_details"] = error.diagnostic
                state.update(cleanup="failed", cleanup_exception_kind=exception_kind(error))
                if failure is None:
                    state.update(phase="cleanup", exception_kind=exception_kind(error))
                    failure = error if isinstance(error, PreparationError) else PreparationError("macos_rust_dwarfdump_failed")
            finally:
                state["returncode"] = process.returncode
                state["reaped"] = process.returncode is not None
                try:
                    process.stdout.close()
                    state["pipe_closed"] = True
                except Exception as error:
                    state["pipe_closed"] = process.stdout.closed
                    state.update(cleanup="failed", cleanup_exception_kind=exception_kind(error))
                    if failure is None:
                        state.update(phase="cleanup", exception_kind=exception_kind(error))
                        failure = PreparationError("macos_rust_dwarfdump_failed")
        if diagnostic is not None:
            diagnostic.update(safe_diagnostic(state))
    if failure is not None:
        summary = safe_diagnostic(state)
        retain_failure_diagnostic(preparation_code(failure), [summary])
        raise PreparationError(preparation_code(failure), diagnostic=summary) from None
    return found


def resolve_apple_tool(name: str, *, timeout=30) -> str:
    explicit = shutil.which(name)
    if explicit:
        return explicit
    try:
        result = subprocess.run(["xcrun", "--find", name], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise PreparationError("apple_debug_tool_lookup_timeout") from None
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
        self.configuration = configuration
        self.artifacts, self.limitations, self.required = [], [], []

    def limitation(self, target, architecture, source, reason):
        self.limitations.append(dict(target=target, architecture=architecture, source=source, reason=reason))

    def _budget(self):
        if time.monotonic() >= self.deadline:
            raise PreparationError("macos_symbol_preparation_timeout")

    def _problem(self, error):
        code = preparation_code(error)
        if code not in self.failures:
            self.failures.append(code)
        detail = safe_diagnostic(getattr(error, "diagnostic", None) or
                                 dict(phase=self.phase, exception_kind=exception_kind(error)))
        if detail not in self.diagnostics and len(self.diagnostics) < MAX_PREPARATION_MODULES:
            self.diagnostics.append(detail)
        return code

    def _tool(self, name):
        self._budget()
        if name not in self.tools:
            self.tools[name] = resolve_apple_tool(name, timeout=min(30, max(.001, self.deadline - time.monotonic())))
        self._budget()
        return self.tools[name]

    def _register_companion(self, path, origin):
        actual = path.resolve()
        if actual not in self.companions:
            if len(self.companions) >= MAX_COMPANION_INPUTS:
                raise PreparationError("macos_symbol_preparation_limit_exceeded")
            self.companions[actual] = (variants(actual), origin)
        return actual

    def _usable(self, item):
        return (item["filetype"] == 10 and item["has_debug_info"] and item["has_debug_line"]
                and not item["has_executable_text"])

    def _matches(self, architecture, identifier):
        return [(path, item, origin) for path, (items, origin) in self.companions.items()
                for item in items if item["architecture"] == architecture and item["uuid"] == identifier]

    def _code_signature(self, path, item):
        key = (path.resolve(), item["architecture"])
        if key not in self.code_signatures:
            result = []
            with path.open("rb") as stream:
                for section in item["sections"]:
                    if not section["has_contents"] or not (section["name"] == "__text" or section["flags"] & 0x80000400):
                        continue
                    if section["size"] > MAX_DEBUG_PAYLOAD:
                        raise PreparationError("macos_symbol_preparation_limit_exceeded")
                    digest, remaining = hashlib.sha256(), section["size"]
                    stream.seek(section["offset"])
                    while remaining:
                        self._budget()
                        chunk = stream.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise PreparationError("invalid_macos_source_image")
                        digest.update(chunk)
                        remaining -= len(chunk)
                    result.append((section["segment"], section["name"], section["addr"], section["size"], digest.digest()))
            self.code_signatures[key] = tuple(result)
        return self.code_signatures[key]

    def _products_sources(self, binary, slices):
        sources = {item["architecture"]: [] for item in slices}
        counts = {item["architecture"]: [0, 0] for item in slices}
        seen = set()
        for candidate in self.products.rglob(binary.name):
            self._budget()
            if not candidate.is_file():
                continue
            actual = candidate.resolve()
            if actual.is_relative_to(self.app) or actual in seen:
                continue
            if not actual.is_relative_to(self.products.resolve()):
                raise PreparationError("macos_source_image_escaped_products")
            seen.add(actual)
            if self.source_candidates >= MAX_SOURCE_CANDIDATES:
                raise PreparationError("macos_symbol_preparation_limit_exceeded")
            self.source_candidates += 1
            try:
                if static_archive_architectures(actual) is not None or not is_macho(actual):
                    continue
                items = variants(actual)
            except (MachoError, OSError):
                raise PreparationError("invalid_macos_source_image") from None
            for runtime in slices:
                item = next((entry for entry in items if entry["architecture"] == runtime["architecture"]
                             and entry["uuid"] == runtime["uuid"] and entry["filetype"] in {2, 6, 8}
                             and entry["has_oso_symbols"]), None)
                if item is None:
                    continue
                counts[item["architecture"]][0] += 1
                signature = self._code_signature(actual, item)
                if signature and signature == self._code_signature(binary, runtime):
                    sources[item["architecture"]].append(actual)
                else:
                    counts[item["architecture"]][1] += 1
        return sources, counts

    def _generate(self, binary, target, origin, row):
        self._budget()
        actual = binary.resolve()
        if actual in self.generated:
            return
        if (len(self.generated) >= MAX_GENERATED_DSYMS
                or self.module_generations.get(target, 0) >= MAX_MODULE_GENERATIONS):
            raise PreparationError("macos_symbol_preparation_limit_exceeded")
        self.generated.add(actual)
        self.module_generations[target] = self.module_generations.get(target, 0) + 1
        destination = self.output / "generated" / (str(len(self.generated)) + ".dSYM")
        destination.parent.mkdir(parents=True, exist_ok=True)
        row["dsymutil_attempts"] += 1
        try:
            tool = self.dsymutil or self._tool("dsymutil")
            self._budget()
            self.dsymutil_runs += 1
            completed = run_dsymutil(tool, actual, destination,
                                    timeout=min(DSYMUTIL_TIMEOUT, max(.001, self.deadline - time.monotonic())))
        except PreparationError as error:
            row["dsymutil_timeouts"] += str(error) == "macos_dsymutil_timeout"
            row["generation_failure"] = preparation_code(error)
            return
        row["dsymutil_exit_codes"].append(completed.returncode)
        files = list((destination / "Contents/Resources/DWARF").glob("*"))
        if completed.returncode == 0 and len(files) == 1:
            self._register_companion(files[0], origin)

    def _normalize(self, source, item, target, slice_count):
        suffix = "-" + item["architecture"] if slice_count > 1 else ""
        destination = self.output / (target + suffix + ".dSYM/Contents/Resources/DWARF") / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Copy the exact MH_DSYM slice, with offsets inside its load commands
        # unchanged. Never merge line-less siblings or copy runtime text.
        with source.open("rb") as incoming, destination.open("wb") as output:
            incoming.seek(item["offset"])
            remaining = item["size"]
            while remaining:
                self._budget()
                chunk = incoming.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise PreparationError("truncated_macos_debug_slice")
                output.write(chunk)
                remaining -= len(chunk)
        checked = variants(destination)
        if (len(checked) != 1 or checked[0]["architecture"] != item["architecture"]
                or checked[0]["uuid"] != item["uuid"] or not self._usable(checked[0])):
            raise PreparationError("invalid_macos_symbol_input")
        return destination

    def _write_report(self):
        destination = self.root / "macos/sentry-symbol-preparation.json"
        if destination.is_symlink() or not destination.resolve().is_relative_to(self.root):
            raise PreparationError("unsafe_macos_symbol_preparation_report")
        destination.parent.mkdir(parents=True, exist_ok=True)
        required = [row for row in self.rows if row["required"]]
        value = dict(schema_version=1, platform="macos", status="failed" if self.failures else "complete",
                     elapsed_seconds=round(time.monotonic() - self.started, 2),
                     timeout_seconds=PREPARATION_TIMEOUT, generation_limit=MAX_GENERATED_DSYMS,
                     module_generation_limit=MAX_MODULE_GENERATIONS, failures=self.failures, diagnostics=self.diagnostics,
                     counts=dict(modules=self.module_count, slices=len(self.rows), required_slices=len(required),
                                 ready_slices=sum(row["ready"] for row in self.rows),
                                 failed_required_slices=sum(not row["ready"] for row in required),
                                 companion_inputs=len(self.companions), products_candidates=self.source_candidates,
                                 generation_inputs_attempted=len(self.generated), dsymutil_runs=self.dsymutil_runs), modules=self.rows)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile("w", dir=destination.parent, prefix=".sentry-symbol-preparation-", delete=False) as stream:
                temporary = Path(stream.name)
                json.dump(value, stream, indent=2, sort_keys=True)
                stream.write("\n")
            temporary.replace(destination)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def prepare(self):
        self.started = time.monotonic()
        self.deadline = self.started + PREPARATION_TIMEOUT
        self.rows, self.failures, self.companions, self.generated = [], [], {}, set()
        self.diagnostics, self.phase = [], "prepare"
        self.code_signatures, self.module_generations = {}, {}
        self.tools = {}
        self.source_candidates, self.module_count = 0, 0
        self.dsymutil_runs = 0
        self.artifacts, self.limitations, self.required = [], [], []
        try:
            if self.output.is_symlink() or not self.output.resolve().is_relative_to(self.root):
                raise PreparationError("unsafe_macos_symbol_output")
            if self.output.exists():
                shutil.rmtree(self.output)
            self.output.mkdir(parents=True)
            previous_report = self.root / "macos/sentry-symbol-preparation.json"
            if previous_report.is_symlink() or not previous_report.resolve().is_relative_to(self.root):
                raise PreparationError("unsafe_macos_symbol_preparation_report")
            previous_report.unlink(missing_ok=True)
            return self._prepare_all()
        except Exception as error:
            self._problem(error)
            raise PreparationError(preparation_code(error), diagnostic=getattr(error, "diagnostic", None)
                                   or self.diagnostics[-1]) from None
        finally:
            if self.failures:
                self._remove_manifest()
            try:
                self._write_report()
            except Exception as error:
                self._remove_manifest()
                self.phase = "report"
                self._problem(error)
                retain_failure_diagnostic("macos_symbol_preparation_report_failed", self.diagnostics)
                raise PreparationError("macos_symbol_preparation_report_failed") from None
            if self.failures:
                retain_failure_diagnostic(self.failures[0], self.diagnostics)

    def _remove_manifest(self):
        # Retry safety checks can fail before an output directory is trusted.
        # Never follow a replaced output symlink merely to clean a stale file.
        if not self.output.is_symlink() and self.output.resolve().is_relative_to(self.root):
            (self.output / "manifest.json").unlink(missing_ok=True)

    def _prepare_all(self):
        self.phase = "inventory"
        try:
            metadata = load_inventory(self.root, self.app, self.configuration)
            owned = {item["product"]: item for item in metadata["products"]}
            with (self.app / "Contents/Info.plist").open("rb") as stream:
                executable = plistlib.load(stream)["CFBundleExecutable"]
        except (OSError, KeyError, ValueError, TypeError, InventoryError):
            raise PreparationError("macos_owned_or_bundle_metadata_missing") from None
        runner = (self.app / "Contents/MacOS" / executable).resolve()
        inventory = macho_inventory(self.app)
        self.module_count = len(inventory)
        if runner not in inventory:
            raise PreparationError("macos_runner_macho_missing")
        if len(inventory) > MAX_PREPARATION_MODULES:
            raise PreparationError("macos_symbol_preparation_limit_exceeded")
        plans, present_products, targets = [], set(), set()
        has_rust = has_core = has_dart = False
        for binary in inventory:
            framework = next((part for part in binary.relative_to(self.app).parts if part.endswith(".framework")), None)
            target = "runner" if binary == runner else safe_label(binary.name)
            product = framework or binary.name
            present_products.add(product)
            source = "runner" if binary == runner else owned.get(product, {}).get("source", "prebuilt")
            if binary.name == "rust_api" and framework == "rust_api.framework":
                source, has_rust = "rust", True
            elif binary.name == "FlClashCore":
                source, has_core = "go", True
            dart = framework == "App.framework" and binary.name == "App"
            has_dart |= dart
            if target in targets:
                raise PreparationError("duplicate_macos_module_target")
            targets.add(target)
            slices = variants(binary)
            rows = []
            for item in slices:
                row = dict(target=target, source="dart" if dart else source, architecture=item["architecture"],
                           debug_id=item["uuid"], required=not dart and source != "prebuilt", ready=False,
                           runtime_has_oso=item["has_oso_symbols"], existing_uuid_matches=0, existing_usable_matches=0,
                           existing_debug_info_matches=0, existing_debug_line_matches=0, existing_debug_only_matches=0,
                           products_oso_matches=0, products_code_mismatches=0, origin="none", has_debug_info=False,
                           products_promoted_module=False,
                           has_debug_line=False, no_executable_text=False, rust_cu_checked=False,
                           dsymutil_attempts=0, dsymutil_timeouts=0, dsymutil_exit_codes=[], failure="none")
                rows.append(row)
                self.rows.append(row)
            plans.append((binary, target, source, dart, slices, rows))
        for root, origin in ((self.products, "existing_products"), (self.root.parent / "libclash/macos", "existing_core"),
                             (self.root / "macos/sentry-prebuilt-dsyms", "existing_vendor")):
            self.phase = "companions"
            for path in dwarf_files(root):
                try:
                    self._budget()
                    if not path.resolve().is_relative_to(root.resolve()):
                        raise PreparationError("invalid_macos_symbol_input")
                    self._register_companion(path, origin)
                except Exception as error:
                    self._problem(error)
                    if preparation_code(error) in {"macos_symbol_preparation_limit_exceeded", "macos_symbol_preparation_timeout"}:
                        break
        for binary, target, source, dart, slices, rows in plans:
            if dart:
                for row in rows:
                    row["origin"] = "dart_managed_separately"
                    self.limitation(target, row["architecture"], "dart", "split_debug_info_managed_separately")
                continue
            try:
                self.phase = "products"
                products_sources, source_counts = self._products_sources(binary, slices)
                # Match audit's independent Products/OSO ownership discovery,
                # including native-assets modules absent from Pods/SPM metadata.
                promoted = any(count[0] for count in source_counts.values())
                for row in rows:
                    row["required"] |= bool(promoted)
                    row["products_promoted_module"] = bool(promoted)
                    row["products_oso_matches"], row["products_code_mismatches"] = source_counts[row["architecture"]]
            except Exception as error:
                code = self._problem(error)
                for row in rows:
                    row["failure"] = code
                continue
            for item, row in zip(slices, rows):
                try:
                    self.phase = "normalize"
                    self._budget()
                    matches = self._matches(item["architecture"], item["uuid"])
                    existing = [entry for entry in matches if entry[2].startswith("existing_")]
                    row["existing_uuid_matches"] = len(existing)
                    row["existing_debug_info_matches"] = sum(entry[1]["has_debug_info"] for entry in existing)
                    row["existing_debug_line_matches"] = sum(entry[1]["has_debug_line"] for entry in existing)
                    row["existing_debug_only_matches"] = sum(entry[1]["filetype"] == 10 and not entry[1]["has_executable_text"] for entry in existing)
                    usable = [entry for entry in matches if self._usable(entry[1])]
                    row["existing_usable_matches"] = sum(self._usable(entry[1]) for entry in existing)
                    if not usable and row["required"] and source != "go":
                        inputs = [(path, "generated_products_oso") for path in products_sources[item["architecture"]]]
                        if item["has_oso_symbols"]:
                            inputs.append((binary, "generated_final_oso"))
                        for candidate, origin in inputs:
                            self._generate(candidate, target, origin, row)
                            usable = [entry for entry in self._matches(item["architecture"], item["uuid"]) if self._usable(entry[1])]
                            if usable:
                                break
                    if not usable:
                        if row["required"]:
                            raise PreparationError("required_macos_matching_dsym_unavailable")
                        row["origin"] = "explicit_prebuilt_limitation"
                        self.limitation(target, item["architecture"], source, "prebuilt_debug_companion_unavailable")
                        continue
                    original, debug, origin = usable[0]
                    destination = self._normalize(original, debug, target, len(slices))
                    row.update(origin=origin, has_debug_info=True, has_debug_line=True, no_executable_text=True)
                    if source == "rust":
                        self.phase = "rust_debug"
                        self._budget()
                        row["rust_cu_checked"] = True
                        row["rust_reader"] = {}
                        if not contains_rust_debug(self.dwarfdump or self._tool("dwarfdump"), destination,
                                architecture=item["architecture"], timeout=min(RUST_DWARFDUMP_TIMEOUT, max(.001, self.deadline - time.monotonic())),
                                diagnostic=row["rust_reader"]):
                            raise PreparationError("rust_framework_missing_rust_compilation_units")
                    row["ready"] = True
                    self.artifacts.append(dict(target=target, architecture=item["architecture"], source=source,
                        binary=binary.relative_to(self.root).as_posix(), debug_file=destination.relative_to(self.root).as_posix()))
                    if row["required"]:
                        self.required.append(dict(target=target, architecture=item["architecture"]))
                    if source == "go":
                        self.limitation(target, item["architecture"], source, "separate_process_no_sentry_sdk")
                except Exception as error:
                    row["failure"] = self._problem(error)
        if not has_rust or not has_core or not has_dart or not owned.keys() <= present_products:
            self._problem(PreparationError("required_macos_native_product_missing"))
        required_targets = {item["target"] for item in self.required}
        if any(not set(item["hosts"]) <= required_targets
               for item in required_source_targets(metadata["source_targets"])):
            self._problem(PreparationError("static_macos_package_host_dsym_missing"))
        if self.failures:
            raise PreparationError(self.failures[0], diagnostic=self.diagnostics[0])
        host_architectures = {}
        for _, target, _, _, slices, _ in plans:
            host_architectures[target] = {item["architecture"] for item in slices}
        try:
            self.limitations.extend(source_line_limitations(metadata["source_targets"], host_architectures))
        except InventoryError:
            raise PreparationError("source_macos_package_host_architecture_missing") from None
        for item in metadata["binary_targets"]:
            for host in set(item["hosts"]) - set(item["dynamic_hosts"]):
                for architecture in sorted(host_architectures[host]):
                    self.limitation(item["target"], architecture, "prebuilt",
                                    "static_binary_package_debug_coverage_unverified")
        result = dict(schema_version=1, platform="macos", app=self.app.relative_to(self.root).as_posix(),
                      artifacts=self.artifacts, required=self.required, limitations=self.limitations)
        manifest = self.output / "manifest.json"
        self.phase = "manifest"
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
        print(preparation_code(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, MachoError):
        print("macos_symbol_preparation_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
