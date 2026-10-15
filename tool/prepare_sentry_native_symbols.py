#!/usr/bin/env python3
"""Separate build-matched ELF debug companions; never build or upload anything."""

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
import zipfile

from sentry_elf import ElfError, inspect_elf
from sentry_android_prefab import PrefabError, SENTRY_ANDROID_TARGETS, prefab_candidates

ANDROID_ARCH = {"armeabi-v7a": "arm", "arm64-v8a": "aarch64", "x86_64": "x86_64"}
LINUX_ARCH = {"x64": "x86_64", "arm64": "aarch64"}
OWN_ANDROID = {"libcore.so": "cmake", "libclash.so": "go", "librust_api.so": "rust"}
# rust_api currently declares desktop/iOS platforms only. If an APK ever
# contains its ELF, treat that distributed module as owned and require symbols.
REQUIRED_ANDROID = {"libcore.so", "libclash.so"}
MAX_ELF = 512 * 1024 * 1024


class PreparationError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as reader:
        for chunk in iter(lambda: reader.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_objcopy(platform: str, repo: Path) -> str:
    if platform == "android":
        version_file = repo / "android/gradle/libs.versions.toml"
        version = re.search(r'(?m)^ndkVersion\s*=\s*"([0-9.]+)"', version_file.read_text())
        ndks = [Path(os.environ[key]) for key in ("ANDROID_NDK", "ANDROID_NDK_HOME")
                if os.environ.get(key)]
        if version:
            ndks += [Path(os.environ[key]) / "ndk" / version.group(1)
                     for key in ("ANDROID_HOME", "ANDROID_SDK_ROOT") if os.environ.get(key)]
        for ndk in ndks:
            for candidate in sorted(ndk.glob("toolchains/llvm/prebuilt/*/bin/llvm-objcopy*")):
                if candidate.is_file() and os.access(candidate, os.X_OK):
                    return str(candidate)
        raise PreparationError("android_ndk_objcopy_unavailable")
    executable = shutil.which("objcopy") or shutil.which("llvm-objcopy")
    if not executable:
        raise PreparationError("elf_objcopy_unavailable")
    return executable


class Preparer:
    def __init__(self, build_root: Path, platform: str, objcopy: str):
        self.root = build_root.resolve()
        self.repo = self.root.parent
        self.platform = platform
        self.objcopy = objcopy
        self.output = self.root / "sentry-native" / platform
        # Each invocation starts clean, so a failed run cannot leave a valid old manifest.
        if self.output.is_symlink() or not self.output.resolve().is_relative_to(self.root):
            raise PreparationError("unsafe_output_directory")
        if self.output.exists():
            shutil.rmtree(self.output)
        self.output.mkdir(parents=True)
        self.artifacts = []
        self.limitations = []
        self.required = set()
        self._seen = set()

    def limitation(self, target: str, architecture: str, source: str, reason: str):
        item = dict(target=target, architecture=architecture, source=source, reason=reason)
        if item not in self.limitations:
            self.limitations.append(item)

    def _info(self, path: Path):
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_ELF:
            raise PreparationError("unsafe_native_input")
        try:
            return inspect_elf(path)
        except (ElfError, OSError) as error:
            raise PreparationError("invalid_native_elf") from error

    def add(self, target: str, architecture: str, binary: Path,
            candidates: list[Path], source: str, required: bool):
        if required:
            self.required.add((target, architecture))
        actual = self._info(binary)
        expected_arch = (ANDROID_ARCH if self.platform == "android" else LINUX_ARCH)[architecture]
        if actual["architecture"] != expected_arch:
            raise PreparationError("missing_or_invalid_runtime_build_id")
        if not actual["build_id"]:
            if required:
                raise PreparationError("missing_or_invalid_runtime_build_id")
            self.limitation(target, architecture, source, "prebuilt_build_id_unavailable")
            return
        key = (target, architecture)
        if key in self._seen:
            existing = next(x for x in self.artifacts
                            if (x["target"], x["architecture"]) == key)
            if sha256(self.root / existing["binary"]) != sha256(binary):
                raise PreparationError("conflicting_package_native_modules")
            return
        matching = []
        for candidate in candidates:
            if not candidate.is_file() or candidate.is_symlink():
                continue
            info = self._info(candidate)
            if (info["build_id"] == actual["build_id"]
                    and info["architecture"] == expected_arch
                    and info["has_debug_info"] and info["has_debug_line"]):
                matching.append(candidate)
        if not matching:
            if required:
                raise PreparationError("required_native_dwarf_unavailable")
            self.limitation(target, architecture, source, "prebuilt_debug_companion_unavailable")
            return
        debug = self.output / architecture / (target + ".debug")
        debug.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run([self.objcopy, "--only-keep-debug", str(matching[0]), str(debug)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode:
            raise PreparationError("debug_companion_extraction_failed")
        # --only-keep-debug turns allocated unwind sections into NOBITS. Restore
        # their original contents/addresses without restoring executable code.
        # LLVM requires materializing the section before --update-section.
        with tempfile.TemporaryDirectory(prefix="sentry-cfi-", dir=self.output) as temporary:
            for section in self._info(matching[0])["unwind_sections"]:
                content = Path(temporary) / section
                commands = [
                    ["--dump-section", f"{section}={content}", str(matching[0])],
                    ["--set-section-flags", f"{section}=alloc,load,readonly,data,contents", str(debug)],
                    ["--update-section", f"{section}={content}", str(debug)],
                ]
                for command in commands:
                    completed = subprocess.run([self.objcopy, *command], stdout=subprocess.DEVNULL,
                                               stderr=subprocess.DEVNULL)
                    if completed.returncode:
                        raise PreparationError("unwind_companion_extraction_failed")
        info = self._info(debug)
        if (info["build_id"] != actual["build_id"] or info["has_executable_text"]
                or not info["has_debug_info"] or not info["has_debug_line"]
                or not set(actual["unwind_sections"]) <= set(info["unwind_sections"])):
            raise PreparationError("invalid_debug_companion")
        self.artifacts.append(dict(target=target, architecture=architecture, source=source,
                                   binary=binary.relative_to(self.root).as_posix(),
                                   debug_file=debug.relative_to(self.root).as_posix()))
        self._seen.add(key)

    def android(self, packages: list[Path]):
        if not packages:
            raise PreparationError("final_apk_required")
        candidates = {}
        for package_index, package in enumerate(packages):
            with zipfile.ZipFile(package) as archive:
                names = [x.filename for x in archive.infolist()]
                if len(names) != len(set(names)):
                    raise PreparationError("duplicate_apk_entries")
                entries = {}
                for item in archive.infolist():
                    match = re.fullmatch(r"lib/([^/]+)/([A-Za-z0-9_.-]+\.so)", item.filename)
                    if not match:
                        continue
                    abi, name = match.groups()
                    if abi not in ANDROID_ARCH:
                        self.limitation(name, abi, "prebuilt", "unsupported_flutter_abi")
                        continue
                    if item.file_size > MAX_ELF:
                        raise PreparationError("oversize_apk_native_module")
                    binary = self.output / "runtime" / str(package_index) / abi / name
                    binary.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(item) as reader, binary.open("wb") as writer:
                        shutil.copyfileobj(reader, writer)
                    entries.setdefault(abi, {})[name] = binary
                # A real Flutter ABI contains libapp or libflutter. Extra transitive
                # library-only ABIs do not imply that this app supports that ABI.
                for abi, modules in entries.items():
                    if not ({"libapp.so", "libflutter.so"} & modules.keys()):
                        for name in modules:
                            self.limitation(name, abi, "prebuilt", "not_a_flutter_runtime_abi")
                        continue
                    if not REQUIRED_ANDROID <= modules.keys():
                        raise PreparationError("required_apk_native_module_missing")
                    for name, binary in sorted(modules.items()):
                        if name == "libapp.so":
                            self.limitation(name, abi, "dart", "split_debug_info_managed_separately")
                            continue
                        if name in SENTRY_ANDROID_TARGETS:
                            # Maven prefab libraries retain the upstream DWARF
                            # stripped from their packaged JNI counterparts.
                            # Keep full prefab ELFs local and short-lived; only
                            # the existing debug-only path may enter the manifest.
                            with tempfile.TemporaryDirectory(prefix="sentry-prefab-", dir=self.output) as temporary:
                                try:
                                    sources = prefab_candidates(binary, abi, name, Path(temporary))
                                except PrefabError as error:
                                    raise PreparationError(str(error)) from error
                                self.add(name, abi, binary, sources, "sentry_prefab", True)
                            continue
                        if name not in candidates:
                            roots = [self.root / "core", self.root / "rust_api",
                                     self.root / "app" / "intermediates" / "merged_native_libs"]
                            candidates[name] = [p for root in roots if root.exists()
                                                for p in root.rglob(name)]
                            candidates[name] += list((self.repo / "libclash" / "android").glob("*/" + name))
                        source = OWN_ANDROID.get(name, "gradle")
                        self.add(name, abi, binary, candidates[name], source, name in OWN_ANDROID)
                        if name in {"libcore.so", "libclash.so"}:
                            self.limitation(name, abi, source, "separate_process_no_sentry_sdk")

    def linux(self, architecture: str, configuration: str):
        native = self.root / "linux" / architecture / configuration
        bundle = native / "bundle"
        manifest = native / f"sentry-native-{configuration.capitalize()}.tsv"
        if not manifest.is_file():
            raise PreparationError("cmake_source_manifest_missing")
        sources = {}
        for row in manifest.read_text().splitlines():
            columns = row.split("\t")
            if len(columns) != 2 or not re.fullmatch(r"[A-Za-z0-9_.+-]+", columns[0]):
                raise PreparationError("invalid_cmake_source_manifest")
            original = Path(columns[1]).resolve()
            if not original.is_relative_to(native.resolve()):
                raise PreparationError("unsafe_cmake_source_path")
            sources[original.name] = original
        runner = bundle / "FlClash"
        rust = bundle / "lib" / "librust_api.so"
        if not runner.is_file() or not rust.is_file():
            raise PreparationError("required_bundle_native_module_missing")
        if runner.name not in sources:
            raise PreparationError("runner_source_manifest_missing")
        for binary in [runner, *sorted((bundle / "lib").glob("*.so"))]:
            name = binary.name
            if name == "libapp.so":
                self.limitation(name, architecture, "dart", "split_debug_info_managed_separately")
                continue
            if name == "librust_api.so":
                candidates = list((native / "plugins" / "rust_api").rglob(name))
                source, required = "rust", True
            else:
                if name not in sources:
                    # Do not let a truncated TSV silently reclassify a locally
                    # built plugin as an unavailable prebuilt dependency.
                    local = list((native / "plugins").rglob(name))
                    for candidate in local:
                        info = self._info(candidate)
                        if (info["build_id"] == self._info(binary)["build_id"]
                                and info["has_debug_info"] and info["has_debug_line"]):
                            raise PreparationError("local_plugin_source_manifest_missing")
                candidates = [sources[name]] if name in sources else []
                source, required = ("cmake", True) if candidates else ("prebuilt", False)
            self.add(name, architecture, binary, candidates, source, required)
        core = bundle / "FlClashCore"
        if not core.is_file():
            raise PreparationError("required_bundle_go_core_missing")
        self.add(core.name, architecture, core,
                 [self.repo / "libclash" / "linux" / "FlClashCore"], "go", True)
        self.limitation(core.name, architecture, "go", "separate_process_no_sentry_sdk")

    def finish(self):
        if not self.artifacts:
            raise PreparationError("native_debug_companions_empty")
        path = self.output / "manifest.json"
        path.write_text(json.dumps(dict(schema_version=1, platform=self.platform,
                                        artifacts=self.artifacts, limitations=self.limitations,
                                        required=[dict(target=target, architecture=architecture)
                                                  for target, architecture in sorted(self.required)]),
                                   indent=2) + "\n")
        return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["android", "linux"], required=True)
    parser.add_argument("--build-root", type=Path, default=Path("build"))
    parser.add_argument("--objcopy")
    parser.add_argument("--package", type=Path, action="append", default=[])
    parser.add_argument("--architecture", choices=list(LINUX_ARCH), default="x64")
    parser.add_argument("--configuration", choices=["release", "profile"], default="release")
    args = parser.parse_args(argv)
    try:
        objcopy = args.objcopy or resolve_objcopy(args.platform, args.build_root.resolve().parent)
        preparer = Preparer(args.build_root, args.platform, objcopy)
        if args.platform == "android":
            preparer.android(args.package)
        else:
            preparer.linux(args.architecture, args.configuration)
        preparer.finish()
        print("native_debug_companions_prepared")
        return 0
    except PreparationError as error:
        code = str(error)
        if not re.fullmatch(r"[a-z_]+", code):
            code = "native_debug_companion_preparation_failed"
        print(code, file=sys.stderr)
        return 1
    except (OSError, ValueError, zipfile.BadZipFile):
        print("native_debug_companion_preparation_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
