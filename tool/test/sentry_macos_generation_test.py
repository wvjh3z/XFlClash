#!/usr/bin/env python3
"""Offline macOS symbol fixtures; never compile the Flutter client or core."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
from prepare_sentry_macos_symbols import (  # noqa: E402
    MAX_DEBUG_SECTION, Preparer, PreparationError, extract_go_dsym, variants,
)
from sentry_macho import inspect_macho, read_slices  # noqa: E402


def tool_path(name):
    executable = shutil.which(name)
    if executable:
        return executable
    workspace = TOOL.parent.parents[2]
    patterns = [f".toolchains/android-sdk/ndk/*/toolchains/llvm/prebuilt/*/bin/{name}",
                f".toolchains/rust/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/{name}",
                f".toolchains/sentry-cli-2.58.4/{name}"]
    return next((str(path) for pattern in patterns for path in workspace.glob(pattern) if path.is_file()), None)


CLANG, DSYMUTIL = tool_path("clang"), tool_path("dsymutil")
LINKER = tool_path("ld64.lld") or (shutil.which("ld") if sys.platform == "darwin" else None)
CLI = tool_path("sentry-cli")
MACHO_STRIP = tool_path("llvm-strip") or (shutil.which("strip") if sys.platform == "darwin" else None)


class PodInventoryTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("ruby"), "CocoaPods inventory fixture requires Ruby")
    def test_real_podfile_inventory_excludes_vendored_only_even_with_dummy_file(self):
        podfile = (TOOL.parent / "macos/Podfile").read_text()
        start = podfile.index("  xboard_owned_products = []")
        stop = podfile.index("  installer.pods_project.targets.each", start)
        # Execute the actual post-install selection against CocoaPods-shaped
        # objects; no pod install, network, Xcode or client compilation occurs.
        script = '''require 'json'
Accessor = Struct.new(:source_files)
class PodFixture
  attr_reader :name, :product_name, :file_accessors
  def initialize(name, product, build, files, dynamic = true)
    @name, @product_name, @build = name, product, build
    @dynamic = dynamic
    @file_accessors = [Accessor.new(files)]
  end
  def should_build?; @build; end
  def build_as_dynamic?; @dynamic; end
end
installer = Struct.new(:pod_targets).new([
  PodFixture.new('FlutterMacOS', 'FlutterMacOS.framework', false, ['generated-dummy.m']),
  PodFixture.new('Sentry', 'Sentry.framework', false, []),
  PodFixture.new('example', 'example.framework', true, ['Plugin.swift']),
  PodFixture.new('rust_api', 'rust_api.framework', true, ['dummy_file.c']),
  PodFixture.new('static_dependency', 'static_dependency.framework', true, ['dependency.mm'], false),
])
'''
        script += podfile[start:stop] + "\nputs JSON.generate(xboard_owned_products)\n"
        result = subprocess.run(["ruby", "-e", script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({item["product"] for item in json.loads(result.stdout)},
                         {"example.framework", "rust_api.framework"})


@unittest.skipUnless(CLANG and LINKER and DSYMUTIL, "Mach-O fixture compiler/linker/dsymutil unavailable")
class MacGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix="sentry-macos-fixtures-")
        cls.addClassCleanup(cls.shared.cleanup)
        cls.fixture = Path(cls.shared.name)
        cls.modules = {}
        for index, name in enumerate(("runner", "rust_api", "example", "FlClashCore", "FlutterMacOS", "App")):
            source, object_file = cls.fixture / (name + ".c"), cls.fixture / (name + ".o")
            source.write_text(f"int main(void) {{ return {index + 10}; }}\n")
            binary = cls.fixture / name
            cls.run_command([CLANG, "--target=x86_64-apple-macos11", "-g", "-c", str(source), "-o", str(object_file)])
            cls.run_command([LINKER, "-arch", "x86_64", "-platform_version", "macos", "11.0", "11.0",
                             "-e", "_main", "-o", str(binary), str(object_file)])
            bundle = cls.fixture / (name + ".dSYM")
            cls.run_command([DSYMUTIL, str(binary), "-o", str(bundle)])
            cls.modules[name] = (binary, bundle)

    @staticmethod
    def run_command(command):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sentry-macos-generation-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.products = self.build / "macos/Build/Products/Release"
        self.app = self.products / "中文品牌.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "中文品牌"}, stream)
        shutil.copyfile(self.modules["runner"][0], self.app / "Contents/MacOS/中文品牌")
        shutil.copyfile(self.modules["FlClashCore"][0], self.app / "Contents/MacOS/FlClashCore")
        for name in ("rust_api", "example", "FlutterMacOS", "App"):
            directory = self.app / "Contents/Frameworks" / (name + ".framework")
            path = directory / "Versions/A" / name
            path.parent.mkdir(parents=True)
            shutil.copyfile(self.modules[name][0], path)
            try:
                (directory / "Versions/Current").symlink_to("A", target_is_directory=True)
                (directory / name).symlink_to("Versions/Current/" + name)
            except OSError as error:
                if sys.platform == "win32" and (
                        isinstance(error, PermissionError) or getattr(error, "winerror", None) in {5, 1314}):
                    self.skipTest("Windows fixture needs symbolic-link permission")
                raise
        for name in ("runner", "rust_api", "example", "FlClashCore"):
            shutil.copytree(self.modules[name][1], self.products / (name + ".dSYM"))
        self.owned = self.build / "macos/sentry-native-owned.json"
        self.owned.write_text(json.dumps({"schema_version": 1, "products": [
            {"target": "rust_api", "product": "rust_api.framework"},
            {"target": "example", "product": "example.framework"},
        ]}))

    def prepare(self):
        with mock.patch("prepare_sentry_macos_symbols.contains_rust_debug", return_value=True):
            return Preparer(self.build, dsymutil=DSYMUTIL, dwarfdump="fixture").prepare()

    def test_final_app_uuid_matching_and_unicode_runner_with_framework_symlinks(self):
        manifest = json.loads(self.prepare().read_text())
        self.assertEqual({entry["target"] for entry in manifest["required"]},
                         {"runner", "rust_api", "example", "FlClashCore"})
        self.assertEqual(len(manifest["artifacts"]), 4)
        self.assertTrue(any("中文品牌" in entry["binary"] for entry in manifest["artifacts"]))
        self.assertTrue(any(item["target"] == "FlutterMacOS" and item["source"] == "prebuilt"
                            for item in manifest["limitations"]))
        self.assertTrue(any(item["source"] == "dart" for item in manifest["limitations"]))
        for entry in manifest["artifacts"]:
            runtime, debug = variants(self.build / entry["binary"]), variants(self.build / entry["debug_file"])
            self.assertEqual(runtime[0]["uuid"], debug[0]["uuid"])
            self.assertFalse(debug[0]["has_executable_text"])
            self.assertEqual(debug[0]["filetype"], 10)

    def test_missing_existing_dsym_uses_real_dsymutil_object_map(self):
        shutil.rmtree(self.products / "example.dSYM")
        manifest = json.loads(self.prepare().read_text())
        self.assertTrue(any(entry["target"] == "example" for entry in manifest["artifacts"]))

    @unittest.skipUnless(CLI, "Pinned sentry-cli unavailable")
    def test_production_manifest_passes_real_cli_native_and_dart_offline_audit(self):
        import upload_sentry_symbols as upload
        self.prepare()
        artifacts, evidence, _ = upload.audit_macos(CLI, self.build)
        self.assertEqual(len(artifacts), 4)
        self.assertEqual({item["target"] for item in evidence},
                         {"runner", "rust_api", "example", "FlClashCore"})
        dart = self.build / "debug-info/app.darwin-x86_64.symbols"
        dart.parent.mkdir()
        shutil.copyfile(self.modules["App"][1] / "Contents/Resources/DWARF/App", dart)
        report = self.build / "macos-safe-evidence.json"
        result = upload.main(["--platform", "macos", "--flavor", "brand_a", "--build-root", str(self.build),
                              "--sentry-cli", CLI, "--evidence", str(report), "--audit-only"])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(report.read_text())["status"], "audited")

    def test_go_dsym_is_required_without_claiming_separate_process_capture(self):
        shutil.rmtree(self.products / "FlClashCore.dSYM")
        with self.assertRaisesRegex(PreparationError, "required_macos_matching_dsym_unavailable"):
            self.prepare()

    def test_rust_framework_must_contain_rust_compilation_units(self):
        with mock.patch("prepare_sentry_macos_symbols.contains_rust_debug", return_value=False), \
             self.assertRaisesRegex(PreparationError, "rust_framework_missing_rust_compilation_units"):
            Preparer(self.build, dsymutil=DSYMUTIL, dwarfdump="fixture").prepare()

    def test_missing_owned_framework_fails(self):
        shutil.rmtree(self.app / "Contents/Frameworks/example.framework")
        with self.assertRaisesRegex(PreparationError, "required_macos_native_product_missing"):
            self.prepare()

    def test_missing_owned_inventory_fails(self):
        self.owned.unlink()
        with self.assertRaisesRegex(PreparationError, "macos_owned_or_bundle_metadata_missing"):
            self.prepare()

    def test_multiple_final_apps_require_explicit_choice(self):
        (self.products / "other.app").mkdir()
        with self.assertRaisesRegex(PreparationError, "one_final_macos_app_required"):
            self.prepare()


@unittest.skipUnless(shutil.which("go"), "Go cross-compilation fixture unavailable")
class GoDsymGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix="sentry-go-dsym-fixtures-")
        cls.addClassCleanup(cls.shared.cleanup)
        cls.root = Path(cls.shared.name)
        source = cls.root / "main.go"
        source.write_text('package main\nfunc main(){println("fixture")}\n')
        cls.modules = {}
        for architecture in ("arm64", "amd64"):
            binary = cls.root / ("GoCore-" + architecture)
            result = subprocess.run(["go", "build", "-ldflags=-w -s -s=false -w=false", "-o", str(binary), str(source)],
                                    capture_output=True, text=True,
                                    env={**os.environ, "GOOS": "darwin", "GOARCH": architecture,
                                         "CGO_ENABLED": "0", "GO111MODULE": "off", "GOCACHE": str(cls.root / "cache")})
            if result.returncode:
                raise RuntimeError(result.stderr)
            cls.modules[architecture] = binary

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sentry-go-dsym-output-")
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)

    def test_go_embedded_compressed_dwarf_becomes_debug_only_dsym_for_both_architectures(self):
        for architecture, source in self.modules.items():
            dwarf = extract_go_dsym(source, self.output / (architecture + ".dSYM"))
            runtime, debug = variants(source), variants(dwarf)
            self.assertEqual(runtime[0]["uuid"], debug[0]["uuid"])
            self.assertTrue(debug[0]["has_debug_info"] and debug[0]["has_debug_line"])
            self.assertFalse(debug[0]["has_executable_text"])
            self.assertEqual(debug[0]["filetype"], 10)
            self.assertFalse(any(section["name"].startswith("__zdebug_") for section in read_slices(dwarf)[0]["sections"]))

    @unittest.skipUnless(MACHO_STRIP, "Mach-O strip tool unavailable")
    def test_stripped_go_runtime_keeps_the_exported_dsym_uuid(self):
        for architecture, original in self.modules.items():
            source = self.output / ("GoCore-" + architecture)
            shutil.copyfile(original, source)
            dwarf = extract_go_dsym(source, self.output / (architecture + ".dSYM"))
            result = subprocess.run([MACHO_STRIP, "-S", str(source)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            runtime = variants(source)[0]
            self.assertEqual(runtime["uuid"], variants(dwarf)[0]["uuid"])
            self.assertFalse(runtime["has_debug_info"])

    @unittest.skipUnless(CLI, "Pinned sentry-cli unavailable")
    def test_real_sentry_cli_accepts_go_dsym_line_and_unwind_information(self):
        for architecture, source in self.modules.items():
            dwarf = extract_go_dsym(source, self.output / (architecture + ".dSYM"))
            result = subprocess.run([CLI, "debug-files", "check", "--json", str(dwarf)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            metadata = json.loads(result.stdout)
            self.assertTrue(metadata["is_usable"])
            self.assertIn("debug", metadata["features"])
            self.assertIn("unwind", metadata["features"])

    def test_go_corrupt_compressed_dwarf_is_rejected(self):
        source = self.output / "GoCore"
        source.write_bytes(self.modules["arm64"].read_bytes())
        section = next(section for section in read_slices(source)[0]["sections"]
                       if section["name"].startswith("__zdebug_"))
        with source.open("r+b") as stream:
            stream.seek(section["offset"] + 12)
            stream.write(b"corrupt")
        with self.assertRaisesRegex(PreparationError, "invalid_compressed_go_dwarf"):
            extract_go_dsym(source, self.output / "corrupt.dSYM")

    def test_go_oversize_compressed_dwarf_is_rejected_before_inflation(self):
        source = self.output / "GoCore"
        source.write_bytes(self.modules["arm64"].read_bytes())
        section = next(section for section in read_slices(source)[0]["sections"]
                       if section["name"].startswith("__zdebug_"))
        with source.open("r+b") as stream:
            stream.seek(section["offset"] + 4)
            stream.write(struct.pack(">Q", MAX_DEBUG_SECTION + 1))
        with self.assertRaisesRegex(PreparationError, "oversize_compressed_go_dwarf"):
            extract_go_dsym(source, self.output / "oversize.dSYM")

    def test_fat_go_dsym_preserves_both_architectures_and_identifiers(self):
        cursor, offsets, payloads = 4096, [], []
        for source in self.modules.values():
            item, payload = read_slices(source)[0], source.read_bytes()
            offsets.append((item["cpu_type"], item["cpu_subtype"], cursor, len(payload), 12))
            payloads.append(payload)
            cursor = (cursor + len(payload) + 4095) & ~4095
        data = bytearray(struct.pack(">II", 0xCAFEBABE, len(offsets)))
        for item in offsets:
            data.extend(struct.pack(">iiIII", *item))
        for item, payload in zip(offsets, payloads):
            data.extend(b"\0" * (item[2] - len(data)))
            data.extend(payload)
        source = self.output / "FatGoCore"
        source.write_bytes(data)
        dwarf = extract_go_dsym(source, self.output / "fat.dSYM")
        self.assertEqual({(item["architecture"], item["uuid"]) for item in variants(source)},
                         {(item["architecture"], item["uuid"]) for item in variants(dwarf)})
        self.assertFalse(any(item["has_executable_text"] for item in variants(dwarf)))


if __name__ == "__main__":
    unittest.main()
