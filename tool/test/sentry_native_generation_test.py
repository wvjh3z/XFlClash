#!/usr/bin/env python3
"""Offline ELF fixtures only: never compile the client, Go core or Rust plugin."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
from prepare_sentry_native_symbols import Preparer, PreparationError, resolve_objcopy  # noqa: E402
from sentry_elf import inspect_elf  # noqa: E402


@unittest.skipUnless(sys.platform == "linux" and shutil.which("cc") and shutil.which("objcopy"),
                     "Linux C/ELF fixture tools unavailable")
class GenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name).resolve()
        self.build = self.repo / "build"
        self.build.mkdir()
        code = self.repo / "fixture.c"
        code.write_text('const char* fixture_name(void) { return "sentry-prefab"; }\n'
                        'int fixture(int x) { return x + 42; }\nint main(void) { return fixture(1); }\n')
        self.elf = self.repo / "fixture.so"
        subprocess.run(["cc", "-g", "-shared", "-Wl,--build-id=sha1", str(code), "-o", str(self.elf)], check=True)
        arch = inspect_elf(self.elf)["architecture"]
        if arch not in {"x86_64", "aarch64"}:
            self.skipTest("Unsupported Linux host fixture architecture")
        self.android_abi = {"x86_64": "x86_64", "aarch64": "arm64-v8a"}[arch]
        self.linux_arch = {"x86_64": "x64", "aarch64": "arm64"}[arch]
        self.stripped = self.repo / "stripped.so"
        shutil.copyfile(self.elf, self.stripped)
        subprocess.run(["objcopy", "--strip-debug", str(self.stripped)], check=True)

    def android_fixture(self, omit=None, include_rust=False, include_sentry=False):
        package = self.repo / "fixture.apk"
        names = {"libcore.so", "libclash.so", "libflutter.so"}
        if include_rust:
            names.add("librust_api.so")
        if include_sentry:
            names.update({"libsentry.so", "libsentry-android.so"})
        names -= {omit}
        with zipfile.ZipFile(package, "w") as archive:
            for name in names:
                archive.writestr(f"lib/{self.android_abi}/" + name, self.stripped.read_bytes())
                if name not in {"libflutter.so", "libsentry.so", "libsentry-android.so"}:
                    source = self.build / "core" / "intermediates" / name
                    source.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(self.elf, source)
        return package

    def sentry_cache(self, omit=None):
        home = self.repo / "gradle-home"
        aar = home / "caches/modules-2/files-2.1/io.sentry/sentry-native-ndk/0.16.6/hash/sentry-native-ndk-0.16.6.aar"
        aar.parent.mkdir(parents=True)
        with zipfile.ZipFile(aar, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for module, name in [("sentry", "libsentry.so"), ("sentry-android", "libsentry-android.so")]:
                if name != omit:
                    archive.writestr(f"prefab/modules/{module}/libs/android.{self.android_abi}/{name}",
                                     self.elf.read_bytes())
        return home

    def test_android_sentry_prefab_is_required_and_only_debug_companions_survive(self):
        package = self.android_fixture(include_sentry=True)
        with mock.patch.dict(os.environ, {"GRADLE_USER_HOME": str(self.sentry_cache())}):
            prepare = Preparer(self.build, "android", "objcopy")
            prepare.android([package])
            manifest = json.loads(prepare.finish().read_text())
        self.assertEqual({entry["target"] for entry in manifest["required"]},
                         {"libcore.so", "libclash.so", "libsentry.so", "libsentry-android.so"})
        sentry = [entry for entry in manifest["artifacts"] if entry["source"] == "sentry_prefab"]
        self.assertEqual({entry["target"] for entry in sentry}, {"libsentry.so", "libsentry-android.so"})
        for entry in sentry:
            debug = inspect_elf(self.build / entry["debug_file"])
            self.assertTrue(debug["has_debug_info"] and debug["has_debug_line"])
            self.assertFalse(debug["has_executable_text"])
        self.assertFalse(list(prepare.output.glob("sentry-prefab-*")))
        self.assertFalse(any(entry["target"].startswith("libsentry") for entry in manifest["limitations"]))

    def test_android_sentry_with_missing_prefab_cannot_be_downgraded_to_a_limitation(self):
        package = self.android_fixture(include_sentry=True)
        with mock.patch.dict(os.environ, {"GRADLE_USER_HOME": str(self.sentry_cache(omit="libsentry-android.so"))}):
            prepare = Preparer(self.build, "android", "objcopy")
            with self.assertRaisesRegex(PreparationError, "required_native_dwarf_unavailable"):
                prepare.android([package])
        self.assertFalse((prepare.output / "manifest.json").exists())
        self.assertFalse(list(prepare.output.glob("sentry-prefab-*")))

    def test_android_requires_only_the_sentry_module_present_in_the_apk(self):
        package = self.android_fixture(include_sentry=True, omit="libsentry-android.so")
        with mock.patch.dict(os.environ, {"GRADLE_USER_HOME": str(self.sentry_cache())}):
            prepare = Preparer(self.build, "android", "objcopy")
            prepare.android([package])
            manifest = json.loads(prepare.finish().read_text())
        self.assertEqual({entry["target"] for entry in manifest["required"]},
                         {"libcore.so", "libclash.so", "libsentry.so"})

    def test_android_extracts_matching_debug_only_and_records_actual_apk_bytes(self):
        package = self.android_fixture()
        prepare = Preparer(self.build, "android", "objcopy")
        prepare.android([package])
        manifest = json.loads(prepare.finish().read_text())
        self.assertEqual(len(manifest["artifacts"]), 2)
        self.assertEqual(len(manifest["required"]), 2)
        for item in manifest["artifacts"]:
            debug = self.build / item["debug_file"]
            info = inspect_elf(debug)
            self.assertTrue(info["has_debug_info"] and info["has_debug_line"])
            self.assertFalse(info["has_executable_text"])
            self.assertEqual(info["unwind_sections"], inspect_elf(self.elf)["unwind_sections"])
            self.assertEqual((self.build / item["binary"]).read_bytes(), self.stripped.read_bytes())
        self.assertTrue(any(x["reason"] == "prebuilt_debug_companion_unavailable" for x in manifest["limitations"]))
        self.assertEqual(sum(x["reason"] == "separate_process_no_sentry_sdk" for x in manifest["limitations"]), 2)

    def test_android_missing_own_module_fails(self):
        package = self.android_fixture(omit="libcore.so")
        with self.assertRaisesRegex(PreparationError, "required_apk_native_module_missing"):
            Preparer(self.build, "android", "objcopy").android([package])

    def test_android_rust_is_required_only_when_actually_distributed(self):
        package = self.android_fixture(include_rust=True)
        prepare = Preparer(self.build, "android", "objcopy")
        prepare.android([package])
        manifest = json.loads(prepare.finish().read_text())
        self.assertEqual({entry["target"] for entry in manifest["required"]},
                         {"libcore.so", "libclash.so", "librust_api.so"})

    def test_android_distributed_rust_still_requires_matching_dwarf(self):
        package = self.android_fixture(include_rust=True)
        (self.build / "core/intermediates/librust_api.so").unlink()
        with self.assertRaisesRegex(PreparationError, "required_native_dwarf_unavailable"):
            Preparer(self.build, "android", "objcopy").android([package])

    def test_android_missing_dwarf_fails_and_old_manifest_is_removed(self):
        package = self.android_fixture()
        for file in (self.build / "core").rglob("*.so"):
            shutil.copyfile(self.stripped, file)
        old = self.build / "sentry-native/android/manifest.json"
        old.parent.mkdir(parents=True)
        old.write_text("old")
        with self.assertRaisesRegex(PreparationError, "required_native_dwarf_unavailable"):
            Preparer(self.build, "android", "objcopy").android([package])
        self.assertFalse(old.exists())

    def test_android_wrong_build_id_fails(self):
        package = self.android_fixture()
        other = self.repo / "other.c"
        other.write_text("int other(void) { return 678; }\n")
        subprocess.run(["cc", "-g", "-shared", "-Wl,--build-id=sha1", str(other), "-o",
                        str(self.build / "core/intermediates/libcore.so")], check=True)
        with self.assertRaisesRegex(PreparationError, "required_native_dwarf_unavailable"):
            Preparer(self.build, "android", "objcopy").android([package])

    def linux_fixture(self):
        native = self.build / "linux" / self.linux_arch / "release"
        sources = [native / "intermediates/FlClash", native / "plugins/test/libtest_plugin.so"]
        for original in sources + [native / "plugins/rust_api/librust_api.so"]:
            original.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.elf, original)
            final = native / "bundle" / (original.name if original.name == "FlClash" else "lib/" + original.name)
            final.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.stripped, final)
        (native / "sentry-native-Release.tsv").write_text("".join(f"t{i}\t{p}\n" for i, p in enumerate(sources)))
        core = self.repo / "libclash/linux/FlClashCore"
        core.parent.mkdir(parents=True)
        shutil.copyfile(self.elf, core)
        shutil.copyfile(self.stripped, native / "bundle/FlClashCore")
        return native

    def test_linux_runner_plugin_and_rust_are_matched_without_mutating_bundle(self):
        native = self.linux_fixture()
        before = {p: p.read_bytes() for p in (native / "bundle").rglob("*") if p.is_file()}
        prepare = Preparer(self.build, "linux", "objcopy")
        prepare.linux(self.linux_arch, "release")
        manifest = json.loads(prepare.finish().read_text())
        self.assertEqual(len(manifest["artifacts"]), 4)
        self.assertEqual(len(manifest["required"]), 4)
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def linux_handler_fixture(self):
        native = self.linux_fixture()
        source = native / "_deps/sentry-native-build/crashpad/handler/crashpad_handler"
        source.parent.mkdir(parents=True)
        shutil.copyfile(self.elf, source)
        runtime = native / "bundle/lib/crashpad_handler"
        shutil.copyfile(self.stripped, runtime)
        # Deliberately retain DWARF in a second runtime copy: equal code/IDs,
        # rather than whole-file hashes, determine shared companion coverage.
        copy = native / "bundle/bin/crashpad_handler"
        copy.parent.mkdir()
        shutil.copyfile(self.elf, copy)
        manifest = native / "sentry-native-Release.tsv"
        manifest.write_text(manifest.read_text() + f"handler_target\t{source}\n")
        return native, source, runtime, copy

    def test_linux_extensionless_handler_covers_all_actual_runtime_copies(self):
        native, _, runtime, copy = self.linux_handler_fixture()
        original = {path: path.read_bytes() for path in (native / "bundle").rglob("*") if path.is_file()}
        prepare = Preparer(self.build, "linux", "objcopy")
        prepare.linux(self.linux_arch, "release")
        manifest = json.loads(prepare.finish().read_text())
        handler = next(entry for entry in manifest["artifacts"] if entry["target"] == "crashpad_handler")
        self.assertEqual(handler["source"], "cmake")
        self.assertEqual(set(handler["binary_copies"]),
                         {path.relative_to(self.build).as_posix() for path in (runtime, copy)})
        self.assertIn({"target": "crashpad_handler", "architecture": self.linux_arch}, manifest["required"])
        debug = inspect_elf(self.build / handler["debug_file"])
        self.assertTrue(debug["has_debug_info"] and debug["has_debug_line"])
        self.assertFalse(debug["has_executable_text"])
        self.assertEqual(original, {path: path.read_bytes() for path in original})

    def test_linux_handler_missing_cmake_record_fails_instead_of_becoming_prebuilt(self):
        native, *_ = self.linux_handler_fixture()
        source_map = native / "sentry-native-Release.tsv"
        source_map.write_text("\n".join(line for line in source_map.read_text().splitlines()
                                         if not line.startswith("handler_target\t")) + "\n")
        with self.assertRaisesRegex(PreparationError, "crashpad_source_manifest_missing"):
            Preparer(self.build, "linux", "objcopy").linux(self.linux_arch, "release")

    def test_linux_handler_without_matching_dwarf_fails_and_removes_stale_manifest(self):
        _, source, *_ = self.linux_handler_fixture()
        shutil.copyfile(self.stripped, source)
        old = self.build / "sentry-native/linux/manifest.json"
        old.parent.mkdir(parents=True)
        old.write_text("old")
        with self.assertRaisesRegex(PreparationError, "required_native_dwarf_unavailable"):
            Preparer(self.build, "linux", "objcopy").linux(self.linux_arch, "release")
        self.assertFalse(old.exists())

    def test_linux_handler_source_with_same_build_id_but_different_code_is_rejected(self):
        _, source, runtime, _ = self.linux_handler_fixture()
        code = self.repo / "changed_handler.c"
        code.write_text('const char* fixture_name(void) { return "sentry-prefab"; }\n'
                        'int fixture(int x) { return x + 43; }\nint main(void) { return fixture(1); }\n')
        build_id = inspect_elf(runtime)["build_id"]
        subprocess.run(["cc", "-g", "-shared", "-Wl,--build-id=0x" + build_id,
                        str(code), "-o", str(source)], check=True)
        self.assertEqual(inspect_elf(source)["build_id"], build_id)
        with self.assertRaisesRegex(PreparationError, "required_native_dwarf_unavailable"):
            Preparer(self.build, "linux", "objcopy").linux(self.linux_arch, "release")

    def test_linux_handler_selects_complete_unwind_source_from_same_name_candidates(self):
        native, first, *_ = self.linux_handler_fixture()
        subprocess.run(["objcopy", "--remove-section", ".eh_frame", "--remove-section", ".eh_frame_hdr",
                        str(first)], check=True, capture_output=True)
        second = native / "_deps/complete-handler/crashpad_handler"
        second.parent.mkdir(parents=True)
        shutil.copyfile(self.elf, second)
        source_map = native / "sentry-native-Release.tsv"
        source_map.write_text(source_map.read_text() + f"other_handler_target\t{second}\n")
        prepare = Preparer(self.build, "linux", "objcopy")
        prepare.linux(self.linux_arch, "release")
        manifest = json.loads(prepare.finish().read_text())
        handler = next(entry for entry in manifest["artifacts"] if entry["target"] == "crashpad_handler")
        self.assertEqual(inspect_elf(self.build / handler["debug_file"])["unwind_sections"],
                         inspect_elf(self.elf)["unwind_sections"])

    def test_linux_missing_runner_mapping_fails(self):
        native = self.linux_fixture()
        (native / "sentry-native-Release.tsv").write_text("")
        with self.assertRaisesRegex(PreparationError, "runner_source_manifest_missing"):
            Preparer(self.build, "linux", "objcopy").linux(self.linux_arch, "release")

    def test_linux_missing_go_runtime_fails(self):
        native = self.linux_fixture()
        (native / "bundle/FlClashCore").unlink()
        with self.assertRaisesRegex(PreparationError, "required_bundle_go_core_missing"):
            Preparer(self.build, "linux", "objcopy").linux(self.linux_arch, "release")

    def test_linux_truncated_tsv_cannot_downgrade_local_plugin_to_prebuilt(self):
        native = self.linux_fixture()
        manifest = native / "sentry-native-Release.tsv"
        manifest.write_text(manifest.read_text().splitlines()[0] + "\n")
        with self.assertRaisesRegex(PreparationError, "local_plugin_source_manifest_missing"):
            Preparer(self.build, "linux", "objcopy").linux(self.linux_arch, "release")

    @unittest.skipUnless(shutil.which("cmake"), "CMake build graph fixture unavailable")
    def test_buildkit_rebuilds_existing_output_after_builder_change(self):
        source = self.repo / "incremental_fixture"
        cmake_source = source / "linux"
        cmake_source.mkdir(parents=True)
        buildkit = source / "plugins/setup/buildkit"
        (buildkit / "cmake").mkdir(parents=True)
        original = TOOL.parent / "plugins/setup/buildkit/cmake/buildkit.cmake"
        shutil.copyfile(original, buildkit / "cmake/buildkit.cmake")
        builder = buildkit / "build_tool/lib/src/go_builder.dart"
        builder.parent.mkdir(parents=True)
        builder.write_text("first policy\n")
        launcher = buildkit / "run_build_tool.sh"
        launcher.write_text('''#!/bin/sh
set -eu
mkdir -p "$PROJECT_DIR/libclash/linux"
cat "$PROJECT_DIR/plugins/setup/buildkit/build_tool/lib/src/go_builder.dart" > "$PROJECT_DIR/libclash/linux/FlClashCore"
''')
        launcher.chmod(0o755)
        (cmake_source / "CMakeLists.txt").write_text('''cmake_minimum_required(VERSION 3.13)
project(build_graph NONE)
include("../plugins/setup/buildkit/cmake/buildkit.cmake")
apply_buildkit()
''')
        native = self.build / "incremental"
        def run(command):
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        run(["cmake", "-S", str(cmake_source), "-B", str(native), "-DCMAKE_BUILD_TYPE=Release"])
        command = ["cmake", "--build", str(native), "--target", "setup_buildkit_build"]
        run(command)
        output = source / "libclash/linux/FlClashCore"
        self.assertEqual(output.read_text(), "first policy\n")
        # Keep timestamps ordered even on filesystems with coarse resolution.
        timestamp = output.stat().st_mtime - 2
        os.utime(output, (timestamp, timestamp))
        builder.write_text("updated linker policy\n")
        run(command)
        self.assertEqual(output.read_text(), "updated linker policy\n")

    def test_output_symlink_is_rejected(self):
        external = self.repo / "external"
        external.mkdir()
        (self.build / "sentry-native").symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(PreparationError, "unsafe_output_directory"):
            Preparer(self.build, "linux", "objcopy")

    @unittest.skipUnless(shutil.which("cmake") and shutil.which("c++"), "CMake ELF fixture unavailable")
    def test_real_cmake_helper_and_install_strip_preserve_intermediate_and_build_id(self):
        source = self.repo / "cmake_fixture"
        source.mkdir()
        (source / "main.cpp").write_text("int main() { return 42; }\n")
        (source / "plugin.cpp").write_text("int fixture() { return 42; }\n")
        (source / "handler.cpp").write_text("int main() { return 7; }\n")
        production = (TOOL.parent / "linux/CMakeLists.txt").read_text()
        install_block = production[production.index("# Keep DWARF in build intermediates"):]
        (source / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.13)
project(fixture LANGUAGES CXX)
add_executable(FlClash main.cpp)
add_library(test_plugin SHARED plugin.cpp)
add_executable(handler_target handler.cpp)
set_target_properties(handler_target PROPERTIES OUTPUT_NAME crashpad_handler)
include("{TOOL.parent / 'linux/xboard_sentry_symbols.cmake'}")
set(CMAKE_INSTALL_PREFIX "${{CMAKE_BINARY_DIR}}/bundle")
set(INSTALL_BUNDLE_LIB_DIR "${{CMAKE_INSTALL_PREFIX}}/lib")
install(TARGETS FlClash RUNTIME DESTINATION "${{CMAKE_INSTALL_PREFIX}}")
install(TARGETS test_plugin LIBRARY DESTINATION "${{INSTALL_BUNDLE_LIB_DIR}}")
install(TARGETS handler_target RUNTIME DESTINATION "${{INSTALL_BUNDLE_LIB_DIR}}")
install(TARGETS handler_target RUNTIME DESTINATION "${{CMAKE_INSTALL_PREFIX}}/bin")
{install_block}
''')
        native = self.build / "cmake"
        for command in (["cmake", "-S", str(source), "-B", str(native), "-DCMAKE_BUILD_TYPE=Release"],
                        ["cmake", "--build", str(native)], ["cmake", "--install", str(native)]):
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        for original, runtime in [(native / "FlClash", native / "bundle/FlClash"),
                                  (native / "libtest_plugin.so", native / "bundle/lib/libtest_plugin.so"),
                                  (native / "crashpad_handler", native / "bundle/lib/crashpad_handler"),
                                  (native / "crashpad_handler", native / "bundle/bin/crashpad_handler")]:
            full, small = inspect_elf(original), inspect_elf(runtime)
            self.assertTrue(full["has_debug_info"] and full["has_debug_line"])
            self.assertFalse(small["has_debug_info"])
            self.assertEqual(full["build_id"], small["build_id"])
        # Rust/Go copies must use the same real-path guard as CMake targets,
        # rather than stripping an outside intermediate through an alias.
        for relative in ("FlClashCore", "lib/librust_api.so"):
            original = native / (Path(relative).name + "-unstripped-source")
            shutil.copyfile(native / "FlClash", original)
            before = original.read_bytes()
            installed = native / "bundle" / relative
            installed.symlink_to(original)
            result = subprocess.run(["cmake", "--install", str(native)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("escaped its install bundle", result.stderr)
            self.assertEqual(original.read_bytes(), before)
            self.assertTrue(inspect_elf(original)["has_debug_info"])
            installed.unlink()

    @unittest.skipUnless(shutil.which("go"), "Go fixture tool unavailable")
    def test_real_go_override_flags_preserve_elf_build_id_and_dwarf(self):
        source = self.repo / "fixture.go"
        source.write_text('package main\nfunc main() { println("fixture") }\n')
        output = self.repo / "go_fixture"
        result = subprocess.run(["go", "build", "-ldflags=-w -s -s=false -w=false -B gobuildid",
                                 "-o", str(output), str(source)], capture_output=True, text=True,
                                env={**os.environ, "GO111MODULE": "off", "CGO_ENABLED": "0",
                                     "GOCACHE": str(self.repo / "go-cache")})
        self.assertEqual(result.returncode, 0, result.stderr)
        info = inspect_elf(output)
        self.assertTrue(info["build_id"])
        self.assertTrue(info["has_debug_info"] and info["has_debug_line"])


if __name__ == "__main__":
    unittest.main()
