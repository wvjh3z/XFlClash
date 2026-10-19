#!/usr/bin/env python3
"""Prepare checksum-pinned native AppImageKit without FUSE or system installation.

Only the host tool executes. Both official assets are verified so the contract
probe can use the genuine ARM runtime on an x64 host without executing ARM code.
The returned bin directory is the same PATH entry for CI and local packaging.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import json
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.error
try:
    from .fetch_build_asset import download_asset
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from fetch_build_asset import download_asset

REPO = Path(__file__).resolve().parents[1]
PIN = json.loads((REPO / "tool/appimagetool-version.json").read_text(encoding="utf-8"))
OUTPUT = REPO / ".local-build/packaging-tools/appimagetool"


def host_arch() -> str:
    if platform.system() != "Linux":
        raise RuntimeError("The pinned AppImage tool requires a Linux host")
    machine = platform.machine().lower()
    try:
        return {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}[machine]
    except KeyError:
        raise RuntimeError(f"Unsupported AppImage tool host architecture: {machine}") from None


def elf_machine(data: bytes) -> int:
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise RuntimeError("Expected a little-endian 64-bit ELF")
    return struct.unpack_from("<H", data, 18)[0]


def appimage_offset(data: bytes) -> int:
    """Type-2 runtime ends at the ELF section table, before its SquashFS."""
    elf_machine(data)
    section_offset = struct.unpack_from("<Q", data, 40)[0]
    entry_size, count = struct.unpack_from("<HH", data, 58)
    offset = section_offset + entry_size * count
    if data[8:11] != b"AI\x02" or entry_size != 64 or not count or data[offset:offset + 4] != b"hsqs":
        raise RuntimeError("Invalid pinned type-2 AppImage runtime/SquashFS boundary")
    return offset


def verify_asset(path: Path, arch: str) -> bytes:
    pin = PIN["assets"][arch]
    data = path.read_bytes()
    if len(data) != pin["size"] or hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise RuntimeError(f"AppImage tool checksum mismatch: {path.name}")
    if elf_machine(data) != pin["elf_machine"]:
        raise RuntimeError(f"AppImage tool ELF architecture mismatch: {path.name}")
    appimage_offset(data)
    return data


def fetch_asset(destination: Path, arch: str) -> None:
    pin = PIN["assets"][arch]
    download_asset(destination, pin["url"], pin["size"],
                   token=os.environ.get("APPIMAGETOOL_GITHUB_TOKEN", "").strip())
    try:
        verify_asset(destination, arch)
    except Exception:
        destination.unlink(missing_ok=True)
        raise


def check_version(tool: Path) -> str:
    result = subprocess.run([str(tool), "--version"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
    version = (result.stdout + result.stderr).strip()
    if result.returncode or f"(commit {PIN['version_commit']})" not in version:
        raise RuntimeError(f"Unexpected pinned AppImage tool version: {version}")
    return version


def prepare(output: Path = OUTPUT, asset_directory: Path | None = None, target_arch: str | None = None) -> Path:
    arch = host_arch()
    if target_arch and {"amd64": "x86_64", "arm64": "aarch64"}.get(target_arch, target_arch) != arch:
        raise RuntimeError(f"AppImage tool host {arch} does not match target {target_arch}")
    output = output.absolute()
    if output.is_symlink():
        raise RuntimeError("AppImage tool output must not be a symlink")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Verify every cached/downloaded byte before executing or extracting it.
    cache = output / "downloads"
    cache.mkdir(parents=True, exist_ok=True)
    for asset_arch, pin in PIN["assets"].items():
        target = cache / pin["name"]
        if asset_directory is not None:
            source = asset_directory / pin["name"]
            verify_asset(source, asset_arch)
            if source.resolve() != target.resolve():
                shutil.copyfile(source, target)
        elif not target.exists():
            with tempfile.TemporaryDirectory(prefix=".download-appimagetool-", dir=output.parent) as temporary:
                downloaded = Path(temporary) / pin["name"]
                fetch_asset(downloaded, asset_arch)
                downloaded.replace(target)
        verify_asset(target, asset_arch)
    with tempfile.TemporaryDirectory(prefix=".prepare-appimagetool-", dir=output.parent) as temporary:
        stage = Path(temporary)
        native = cache / PIN["assets"][arch]["name"]
        native.chmod(0o755)
        result = subprocess.run([str(native), "--appimage-extract"], cwd=stage, capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError(f"AppImage tool extraction failed: {result.stderr.decode().strip()}")
        extracted = stage / "squashfs-root"
        version = check_version(extracted / "AppRun")
        for dependency in ("usr/bin/appimagetool", "usr/bin/desktop-file-validate", "usr/lib/appimagekit/mksquashfs"):
            if not (extracted / dependency).is_file():
                raise RuntimeError(f"Pinned AppImage tool dependency missing: {dependency}")
        # The native tool embeds its host runtime regardless of ARCH. A genuine
        # ARM runtime prefix lets the probe test ARM parsing on an x64 host.
        arm_data = verify_asset(cache / PIN["assets"]["aarch64"]["name"], "aarch64")
        runtime = arm_data[:appimage_offset(arm_data)]
        (stage / "runtime-aarch64").write_bytes(runtime)
        binary_dir = stage / "bin"
        binary_dir.mkdir()
        (binary_dir / "appimagetool").write_text(
            '#!/bin/sh\nset -eu\n'
            'XFL_APPIMAGETOOL_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"\n'
            'exec "$XFL_APPIMAGETOOL_ROOT/squashfs-root/AppRun" "$@"\n',
            encoding="utf-8",
        )
        (binary_dir / "appimagetool").chmod(0o755)
        for name in ("squashfs-root", "bin", "runtime-aarch64"):
            destination = output / name
            if destination.is_dir():
                shutil.rmtree(destination)
            elif destination.exists() or destination.is_symlink():
                destination.unlink()
            (stage / name).rename(destination)
    check_version(output / "bin/appimagetool")
    print(f"Prepared {arch} {version}", file=sys.stderr)
    return output / "bin"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--asset-directory", type=Path, help="Reuse predownloaded assets; verify their exact pinned hashes")
    parser.add_argument("--target-arch", choices=("amd64", "arm64", "x86_64", "aarch64"), help="Fail before preparation unless host and package target match")
    parser.add_argument("--print-bin-dir", action="store_true", help="Print only the PATH directory to stdout")
    args = parser.parse_args()
    try:
        binary_dir = prepare(args.output, args.asset_directory, args.target_arch)
    except (OSError, RuntimeError, subprocess.SubprocessError, urllib.error.URLError) as error:
        parser.exit(1, f"AppImage tool preparation failed: {error}\n")
    print(binary_dir if args.print_bin_dir else f"AppImage tool PATH: {binary_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
