"""Inventory installed Linux ELF modules and their local CMake sources offline."""

from __future__ import annotations

import os
from pathlib import Path
import re

from sentry_elf import ElfError, inspect_elf


class LinuxInventoryError(RuntimeError):
    pass


_ARCHITECTURES = {"x64": "x86_64", "arm64": "aarch64"}
_MAX_ELF = 512 * 1024 * 1024


def _resolve(path: Path, reason: str) -> Path:
    try:
        return path.resolve()
    except (OSError, RuntimeError, ValueError) as error:
        raise LinuxInventoryError(reason) from error


def _info(path: Path) -> dict:
    try:
        if path.stat().st_size > _MAX_ELF:
            raise LinuxInventoryError("unsafe_native_input")
        return inspect_elf(path)
    except (OSError, ElfError) as error:
        raise LinuxInventoryError("invalid_native_elf") from error


def _is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.read(4) == b"\x7fELF"
    except OSError as error:
        raise LinuxInventoryError("invalid_native_elf") from error


def _local_files(directory: Path, excluded: Path | None = None):
    """Walk real directories only; callers resolve files before opening them."""
    def failed(_error):
        raise LinuxInventoryError("native_inventory_unavailable")

    for parent, directories, files in os.walk(directory, followlinks=False, onerror=failed):
        parent = Path(parent)
        directories[:] = sorted(name for name in directories
                                 if not (parent / name).is_symlink()
                                 and (excluded is None or parent / name != excluded))
        for name in sorted(files):
            yield parent / name


def collect_linux_inventory(build_root: Path, architecture: str, configuration: str) -> dict:
    """Return actual bundle modules, retaining all same-name runtime copies.

    CMake target labels are deliberately distinct from output basenames. Internal
    bundle symlinks are aliases of their real file, never additional modules.
    No executable is launched and no paths outside the native build are opened.
    """
    if architecture not in _ARCHITECTURES or configuration not in {"release", "profile"}:
        raise LinuxInventoryError("invalid_linux_native_configuration")
    root = _resolve(build_root, "unsafe_native_input")
    native = root / "linux" / architecture / configuration
    bundle = native / "bundle"
    native = _resolve(native, "unsafe_native_input")
    bundle = _resolve(bundle, "unsafe_native_input")
    if not native.is_relative_to(root) or not bundle.is_relative_to(native):
        raise LinuxInventoryError("unsafe_native_input")
    manifest = native / f"sentry-native-{configuration.capitalize()}.tsv"
    if not _resolve(manifest, "unsafe_cmake_source_path").is_relative_to(native):
        raise LinuxInventoryError("unsafe_cmake_source_path")
    if not manifest.is_file():
        raise LinuxInventoryError("cmake_source_manifest_missing")
    try:
        rows = manifest.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise LinuxInventoryError("invalid_cmake_source_manifest") from error
    sources = {}
    for row in rows:
        columns = row.split("\t")
        if (len(columns) != 2 or not re.fullmatch(r"[A-Za-z0-9_.+-]+", columns[0])
                or not columns[1] or not Path(columns[1]).is_absolute()):
            raise LinuxInventoryError("invalid_cmake_source_manifest")
        source = _resolve(Path(columns[1]), "unsafe_cmake_source_path")
        if not source.is_relative_to(native) or source.is_relative_to(bundle):
            raise LinuxInventoryError("unsafe_cmake_source_path")
        candidates = sources.setdefault(source.name, [])
        if source not in candidates:
            candidates.append(source)

    # Check links even in directories we do not traverse: an escaping resource
    # link must not authorize opening a foreign native binary through the bundle.
    if bundle.is_dir():
        for path in bundle.rglob("*"):
            if path.is_symlink() and not _resolve(path, "unsafe_bundle_native_path").is_relative_to(bundle):
                raise LinuxInventoryError("unsafe_bundle_native_path")
    modules, facts, seen = {}, {}, set()
    for path in _local_files(bundle):
        binary = _resolve(path, "unsafe_bundle_native_path")
        if not binary.is_relative_to(bundle):
            raise LinuxInventoryError("unsafe_bundle_native_path")
        if binary in seen or not binary.is_file() or not _is_elf(binary):
            continue
        seen.add(binary)
        info = _info(binary)
        if not info["has_executable_text"]:
            continue
        if info["architecture"] != _ARCHITECTURES[architecture]:
            raise LinuxInventoryError("missing_or_invalid_runtime_build_id")
        name = binary.name
        identity = (info["architecture"], info["build_id"], info["code_sections"],
                    frozenset(info["unwind_sections"]))
        if name in facts and (not info["build_id"] or identity != facts[name]):
            raise LinuxInventoryError("conflicting_bundle_native_modules")
        facts[name] = identity
        modules.setdefault(name, []).append(binary)

    if not {"FlClash", "librust_api.so"} <= modules.keys():
        raise LinuxInventoryError("required_bundle_native_module_missing")
    if "FlClash" not in sources:
        raise LinuxInventoryError("runner_source_manifest_missing")
    if "crashpad_handler" in modules and "crashpad_handler" not in sources:
        raise LinuxInventoryError("crashpad_source_manifest_missing")
    required = {"FlClash", "librust_api.so"} | (modules.keys() & sources.keys())
    if "FlClashCore" in modules:
        required.add("FlClashCore")
    if "crashpad_handler" in modules:
        required.add("crashpad_handler")

    # The TSV is independent of the upload manifest, but it can itself be
    # truncated. Matching local DWARF must never become an optional prebuilt gap.
    undeclared = modules.keys() - sources.keys() - {"librust_api.so", "FlClashCore", "libapp.so"}
    if undeclared:
        for path in _local_files(native, excluded=bundle):
            if path.name not in undeclared:
                continue
            try:
                source = path.resolve()
            except (OSError, RuntimeError, ValueError):
                continue
            if (not source.is_relative_to(native) or source.is_relative_to(bundle)
                    or not source.is_file() or not _is_elf(source)):
                continue
            info = _info(source)
            if (info["build_id"] and info["build_id"] == facts[path.name][1]
                    and info["architecture"] == _ARCHITECTURES[architecture]
                    and info["has_debug_info"] and info["has_debug_line"]):
                raise LinuxInventoryError("local_plugin_source_manifest_missing")

    return dict(native=native, bundle=bundle, sources=sources, modules=modules, required=required)
