#!/usr/bin/env python3
"""Offline macOS symbol fixtures; never compile the Flutter client or core."""

import json
import contextlib
import io
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
from prepare_sentry_macos_symbols import (  # noqa: E402
    MAX_DEBUG_SECTION, Preparer, PreparationError, extract_go_dsym, variants,
)
from sentry_macho import inspect_macho, read_slices  # noqa: E402
from sentry_macos_inventory import INVENTORY, write_inventory  # noqa: E402
import prepare_sentry_macos_symbols as preparation  # noqa: E402


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
LIPO = tool_path("llvm-lipo") or (shutil.which("lipo") if sys.platform == "darwin" else None)
ARCHIVER = tool_path("llvm-ar") or shutil.which("ar")


def fixture_link_command(binary, objects, architecture="x86_64"):
    """Use the native SDK/libSystem on Darwin; retain standalone cross LLVM."""
    if sys.platform == "darwin":
        # Bare Apple ld requires the platform SDK and libSystem (including
        # dyld_stub_binder). The compiler driver supplies both for Intel and
        # ARM hosts while producing the same x86_64 fixture architecture.
        return [CLANG, "--target=" + architecture + "-apple-macos11", "-Wl,-e,_main",
                "-o", str(binary), *map(str, objects)]
    return [LINKER, "-arch", architecture, "-platform_version", "macos", "11.0", "11.0",
            "-e", "_main", "-o", str(binary), *map(str, objects)]


class DebugToolSafetyTests(unittest.TestCase):
    def test_only_actual_rust_language_attribute_lines_are_evidence(self):
        for line in (b"DW_AT_language (DW_LANG_Rust)",
                     b"  DW_AT_language\t(DW_LANG_Rust)\r",
                     b"0x0000002a: DW_AT_language [DW_FORM_data2] (DW_LANG_Rust)"):
            with self.subTest(line=line):
                self.assertTrue(preparation.is_rust_language_attribute(line))
        for line in (b'DW_AT_name ("DW_AT_language DW_LANG_Rust private-token")',
                     b'DW_AT_producer ("DW_AT_language (DW_LANG_Rust)")',
                     b'prefix DW_AT_language (DW_LANG_Rust)',
                     b'DW_AT_language ("DW_LANG_Rust")',
                     b'DW_AT_language (DW_LANG_Rust_fake)',
                     b'DW_AT_language (DW_LANG_C11)',
                     b'DW_AT_language (DW_LANG_Rust) private-token /private/path'):
            with self.subTest(line=line):
                self.assertFalse(preparation.is_rust_language_attribute(line))

    def test_dsymutil_and_lookup_timeouts_have_fixed_safe_codes(self):
        failure = subprocess.TimeoutExpired(["private-token", "/private/path"], 300,
                                            output="private-body", stderr="private-stderr")
        with mock.patch.object(preparation.subprocess, "run", side_effect=failure) as run:
            with self.assertRaises(preparation.PreparationError) as raised:
                preparation.run_dsymutil("fixture-dsymutil", Path("private-binary"), Path("private-output"))
        self.assertEqual(str(raised.exception), "macos_dsymutil_timeout")
        self.assertEqual(run.call_args.kwargs["timeout"], preparation.DSYMUTIL_TIMEOUT)
        with mock.patch.object(preparation.shutil, "which", return_value=None), \
             mock.patch.object(preparation.subprocess, "run", side_effect=failure):
            with self.assertRaises(preparation.PreparationError) as raised:
                preparation.resolve_apple_tool("dsymutil")
        self.assertEqual(str(raised.exception), "apple_debug_tool_lookup_timeout")

    @unittest.skipIf(os.name == "nt", "Bounded pipe fixture uses POSIX executables")
    def test_rust_architecture_is_explicit_and_unsupported_selector_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            tool = root / "dwarfdump"
            tool.write_text("#!" + sys.executable + "\nimport sys\n"
                            "if '--arch=x86_64' in sys.argv: print('DW_AT_language (DW_LANG_Rust)')\n"
                            "elif '--arch=arm64' in sys.argv: print('DW_AT_language (DW_LANG_C11)')\n"
                            "else: print('DW_AT_language (DW_LANG_Rust)')\n")
            tool.chmod(0o755)
            self.assertTrue(preparation.contains_rust_debug(str(tool), root / "input", architecture="x86_64"))
            self.assertFalse(preparation.contains_rust_debug(str(tool), root / "input", architecture="arm64"))
            tool.write_text("#!" + sys.executable + "\nimport sys\n"
                            "print('private unsupported option /private/source', file=sys.stderr)\nsys.exit(2)\n")
            with self.assertRaisesRegex(PreparationError, "^macos_rust_dwarfdump_incomplete$"):
                preparation.contains_rust_debug(str(tool), root / "input", architecture="arm64")
            with self.assertRaisesRegex(PreparationError, "^unsupported_rust_debug_architecture$"):
                preparation.contains_rust_debug(str(tool), root / "input", architecture="arm64e")

    @unittest.skipIf(os.name == "nt", "Bounded pipe fixture uses POSIX executables")
    def test_silent_rust_dwarfdump_timeout_terminates_process_without_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            tool = root / "dwarfdump"
            tool.write_text("#!" + sys.executable + "\nimport time\nprint('private-token /private/path', flush=True)\ntime.sleep(60)\n")
            tool.chmod(0o755)
            original, processes = subprocess.Popen, []
            def launch(*args, **kwargs):
                process = original(*args, **kwargs)
                processes.append(process)
                return process
            output = io.StringIO()
            started = time.monotonic()
            with mock.patch.object(preparation.subprocess, "Popen", side_effect=launch), \
                 contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
                 self.assertRaises(preparation.PreparationError) as raised:
                preparation.contains_rust_debug(str(tool), root / "private-input", timeout=.15)
            self.assertEqual(str(raised.exception), "macos_rust_dwarfdump_timeout")
            self.assertLess(time.monotonic() - started, 3)
            self.assertIsNotNone(processes[0].poll())
            self.assertEqual(output.getvalue(), "")

    @unittest.skipIf(os.name == "nt", "Bounded pipe fixture uses POSIX executables")
    def test_rust_scan_preserves_positive_detection_and_output_cap(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            tool = root / "dwarfdump"
            tool.write_text("#!" + sys.executable + "\nprint('DW_AT_language (DW_LANG_Rust)')\n")
            tool.chmod(0o755)
            self.assertTrue(preparation.contains_rust_debug(str(tool), root / "input", timeout=2))
            tool.write_text("#!" + sys.executable + "\nimport sys\nsys.stdout.write('not-rust' * 10000)\n")
            with mock.patch.object(preparation, "MAX_RUST_DEBUG_OUTPUT", 256):
                with self.assertRaises(preparation.PreparationError) as raised:
                    preparation.contains_rust_debug(str(tool), root / "input", timeout=2)
            self.assertEqual(str(raised.exception), "macos_rust_dwarfdump_output_limit")

    @unittest.skipIf(os.name == "nt", "Bounded pipe fixture uses POSIX executables")
    def test_unproved_rust_output_is_missing_only_after_complete_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            tool = root / "dwarfdump"
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                for exit_code, expected in ((0, None), (7, "macos_rust_dwarfdump_incomplete")):
                    tool.write_text("#!" + sys.executable + "\nimport sys\n"
                                    "print('DW_AT_name (\"DW_AT_language DW_LANG_Rust private-token\")')\n"
                                    "print('/private/path', file=sys.stderr)\n"
                                    f"sys.exit({exit_code})\n")
                    tool.chmod(0o755)
                    if expected is None:
                        self.assertFalse(preparation.contains_rust_debug(str(tool), root / "input", timeout=2))
                    else:
                        with self.assertRaises(preparation.PreparationError) as raised:
                            preparation.contains_rust_debug(str(tool), root / "input", timeout=2)
                        self.assertEqual(str(raised.exception), expected)
                for exit_code in (0, 7):
                    tool.write_text("#!" + sys.executable + "\nimport sys\n"
                                    "sys.stdout.write('DW_AT_language (DW_LANG_Rust)')\n"
                                    f"sys.exit({exit_code})\n")
                    if exit_code == 0:
                        self.assertTrue(preparation.contains_rust_debug(str(tool), root / "input", timeout=2))
                    else:
                        with self.assertRaises(preparation.PreparationError) as raised:
                            preparation.contains_rust_debug(str(tool), root / "input", timeout=2)
                        self.assertEqual(str(raised.exception), "macos_rust_dwarfdump_incomplete")
                # An attribute beyond the cap or appended to an overlong
                # property string cannot become positive evidence.
                tool.write_text("#!" + sys.executable + "\nimport sys\n"
                                "sys.stdout.write('x' * 140000 + 'DW_AT_language (DW_LANG_Rust)\\n')\n")
                self.assertFalse(preparation.contains_rust_debug(str(tool), root / "input", timeout=2))
                with mock.patch.object(preparation, "MAX_RUST_DEBUG_OUTPUT", 256):
                    with self.assertRaises(preparation.PreparationError) as raised:
                        preparation.contains_rust_debug(str(tool), root / "input", timeout=2)
                self.assertEqual(str(raised.exception), "macos_rust_dwarfdump_output_limit")
            self.assertEqual(output.getvalue(), "")


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
        cls.fixture = Path(cls.shared.name).resolve()
        cls.modules = {}
        for index, name in enumerate(("runner", "rust_api", "example", "FlClashCore", "FlutterMacOS", "App")):
            source, object_file = cls.fixture / (name + ".c"), cls.fixture / (name + ".o")
            source.write_text(f"int main(void) {{ return {index + 10}; }}\n")
            binary = cls.fixture / name
            cls.run_command([CLANG, "--target=x86_64-apple-macos11", "-g", "-c", str(source), "-o", str(object_file)])
            cls.run_command(fixture_link_command(binary, [object_file]))
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
        self.root = Path(self.temporary.name).resolve()
        # These general structural fixtures are C images with a rust_api
        # filename. Their Rust language evidence is explicitly simulated;
        # dedicated slice-negative tests exercise the actual checking protocol.
        import upload_sentry_symbols as upload
        for name, value in (("contains_rust_debug", True), ("resolve_apple_tool", "fixture-dwarfdump")):
            patcher = mock.patch.object(upload, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)
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
        self.owned = self.build / INVENTORY
        write_inventory(self.build, self.app, "Release", ["pods"], [
            {"target": "rust_api", "product": "rust_api.framework", "source": "pods"},
            {"target": "example", "product": "example.framework", "source": "pods"},
        ])

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

    @unittest.skipUnless(CLI, "Pinned sentry-cli unavailable")
    def test_static_vendor_host_without_dsym_keeps_both_independent_limits(self):
        import upload_sentry_symbols as upload
        metadata = preparation.load_inventory(self.build, self.app)
        write_inventory(self.build, self.app, "Release",
            sorted(set(metadata["dependency_managers"]) | {"spm"}), metadata["products"],
            metadata["source_targets"], [dict(package="Vendor", target="FlutterMacOS",
                                            hosts=["FlutterMacOS"], dynamic_hosts=[])])
        path = self.prepare()
        manifest = json.loads(path.read_text())
        runtime_limit = next(item for item in manifest["limitations"]
            if item["target"] == "FlutterMacOS" and item["reason"] == "prebuilt_debug_companion_unavailable")
        vendor_limit = next(item for item in manifest["limitations"]
            if item["target"] == "FlutterMacOS" and item["reason"] == "static_binary_package_debug_coverage_unverified")
        self.assertEqual(vendor_limit["architecture"], runtime_limit["architecture"])
        self.assertFalse(any(item["target"] == "FlutterMacOS" for item in manifest["artifacts"]))
        upload.audit_macos(CLI, self.build)
        for removed, message in ((runtime_limit, "explicit limitation"),
                                 (vendor_limit, "static binary package")):
            changed = {**manifest, "limitations": [item for item in manifest["limitations"] if item != removed]}
            path.write_text(json.dumps(changed))
            with self.assertRaisesRegex(upload.SymbolError, message):
                upload.audit_macos(CLI, self.build)

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
        with self.assertRaisesRegex(PreparationError, "macos_owned_or_bundle_metadata_missing"):
            self.prepare()

    def test_missing_owned_inventory_fails(self):
        self.owned.unlink()
        with self.assertRaisesRegex(PreparationError, "macos_owned_or_bundle_metadata_missing"):
            self.prepare()

    def test_multiple_final_apps_require_explicit_choice(self):
        (self.products / "other.app").mkdir()
        with self.assertRaisesRegex(PreparationError, "one_final_macos_app_required"):
            self.prepare()

    def test_same_instance_retries_replace_state_and_remove_stale_success(self):
        preparer = Preparer(self.build, dsymutil=DSYMUTIL, dwarfdump="fixture")
        with mock.patch.object(preparation, "contains_rust_debug", return_value=True):
            first = json.loads(preparer.prepare().read_text())
            second = json.loads(preparer.prepare().read_text())
            self.assertEqual(first, second)
            self.assertEqual(len(second["required"]), len({(item["target"], item["architecture"])
                                                          for item in second["required"]}))
            with mock.patch.object(preparation, "contains_rust_debug", return_value=False):
                with self.assertRaisesRegex(PreparationError, "rust_framework_missing_rust_compilation_units"):
                    preparer.prepare()
            self.assertFalse((preparer.output / "manifest.json").exists())
            failed = json.loads((self.build / "macos/sentry-symbol-preparation.json").read_text())
            self.assertEqual(failed["status"], "failed")
            self.assertEqual(len(failed["modules"]), 6)
            self.assertEqual(first, json.loads(preparer.prepare().read_text()))

    def test_report_failure_removes_success_manifest_without_raw_error(self):
        preparer = Preparer(self.build, dsymutil=DSYMUTIL, dwarfdump="fixture")
        with mock.patch.object(preparation, "contains_rust_debug", return_value=True), \
             mock.patch.object(preparer, "_write_report", side_effect=OSError("private-token /private/path")):
            with self.assertRaisesRegex(PreparationError, "^macos_symbol_preparation_report_failed$"):
                preparer.prepare()
        self.assertFalse((preparer.output / "manifest.json").exists())

    @unittest.skipIf(os.name == "nt", "Directory symlink safety fixture is POSIX-only")
    def test_retry_does_not_follow_replaced_output_symlink_when_cleaning_manifest(self):
        preparer = Preparer(self.build, dsymutil=DSYMUTIL, dwarfdump="fixture")
        outside = self.root / "outside"
        outside.mkdir()
        marker = outside / "manifest.json"
        marker.write_text("private-marker")
        shutil.rmtree(preparer.output)
        preparer.output.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(PreparationError, "^unsafe_macos_symbol_output$"):
            preparer.prepare()
        self.assertEqual(marker.read_text(), "private-marker")

    def test_tool_lookup_failure_is_an_attempt_and_not_a_dsymutil_run(self):
        shutil.rmtree(self.products / "example.dSYM")
        preparer = Preparer(self.build, dwarfdump="fixture")
        with mock.patch.object(preparation, "contains_rust_debug", return_value=True), \
             mock.patch.object(preparation, "resolve_apple_tool", side_effect=PreparationError("apple_debug_tool_unavailable")), \
             mock.patch.object(preparation, "run_dsymutil") as run:
            with self.assertRaisesRegex(PreparationError, "required_macos_matching_dsym_unavailable"):
                preparer.prepare()
        run.assert_not_called()
        report = json.loads((self.build / "macos/sentry-symbol-preparation.json").read_text())
        self.assertEqual(report["counts"]["generation_inputs_attempted"], 1)
        self.assertEqual(report["counts"]["dsymutil_runs"], 0)
        self.assertEqual(next(row for row in report["modules"] if row["target"] == "example")["generation_failure"],
                         "apple_debug_tool_unavailable")

    def test_generation_limits_and_timeout_failures_are_safe_and_aggregate(self):
        shutil.rmtree(self.products / "example.dSYM")
        shutil.rmtree(self.products / "rust_api.dSYM")
        preparer = Preparer(self.build, dsymutil=DSYMUTIL, dwarfdump="fixture")
        with mock.patch.object(preparation, "contains_rust_debug", return_value=True), \
             mock.patch.object(preparation, "MAX_GENERATED_DSYMS", 0), \
             mock.patch.object(preparation, "run_dsymutil") as run:
            with self.assertRaisesRegex(PreparationError, "macos_symbol_preparation_limit_exceeded"):
                preparer.prepare()
        run.assert_not_called()
        report = json.loads((self.build / "macos/sentry-symbol-preparation.json").read_text())
        self.assertEqual(len(report["modules"]), 6)
        self.assertEqual({row["target"] for row in report["modules"] if row["failure"] != "none"}, {"example", "rust_api"})
        self.assertFalse((preparer.output / "manifest.json").exists())
        with mock.patch.object(preparation, "contains_rust_debug", return_value=True), \
             mock.patch.object(preparation, "run_dsymutil", side_effect=PreparationError("macos_dsymutil_timeout")):
            with self.assertRaisesRegex(PreparationError, "required_macos_matching_dsym_unavailable"):
                preparer.prepare()
        report = json.loads((self.build / "macos/sentry-symbol-preparation.json").read_text())
        self.assertEqual(report["counts"]["dsymutil_runs"], 2)
        self.assertEqual(sum(row["dsymutil_timeouts"] for row in report["modules"]), 2)
        with mock.patch.object(preparation, "PREPARATION_TIMEOUT", 0), \
             mock.patch.object(preparation, "run_dsymutil") as run:
            with self.assertRaisesRegex(PreparationError, "macos_symbol_preparation_timeout"):
                preparer.prepare()
        run.assert_not_called()
        self.assertEqual(len(json.loads((self.build / "macos/sentry-symbol-preparation.json").read_text())["modules"]), 6)

    def test_external_generation_exception_is_projected_to_fixed_report_code(self):
        shutil.rmtree(self.products / "example.dSYM")
        output = io.StringIO()
        with mock.patch.object(preparation, "contains_rust_debug", return_value=True), \
             mock.patch.object(preparation, "run_dsymutil", side_effect=OSError("private-token https://user:secret@invalid/?token=secret /private/source")), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaisesRegex(PreparationError, "^macos_symbol_preparation_failed$"):
                Preparer(self.build, dsymutil=DSYMUTIL, dwarfdump="fixture").prepare()
        serialized = (self.build / "macos/sentry-symbol-preparation.json").read_text()
        report = json.loads(serialized)
        self.assertEqual(report["failures"][0], "macos_symbol_preparation_failed")
        self.assertTrue(set(report["failures"]) <= preparation.SAFE_PREPARATION_CODES)
        self.assertEqual(len(report["modules"]), 6)
        self.assertNotIn("private", serialized)
        self.assertNotIn("secret", serialized)
        self.assertNotIn("https", serialized)
        self.assertEqual(output.getvalue(), "")


@unittest.skipUnless(os.name == "posix" and CLANG and LINKER and DSYMUTIL and MACHO_STRIP and LIPO,
                     "Real universal Mach-O/dSYM fixtures require POSIX LLVM or Apple tools")
class MacSliceGenerationTests(MacGenerationTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.fat_fixture = cls.fixture / "universal"
        cls.fat_fixture.mkdir()
        cls.thin = {}
        for architecture in ("arm64", "x86_64"):
            directory = cls.fat_fixture / architecture
            directory.mkdir()
            source, object_file, binary = directory / "fixture.c", directory / "fixture.o", directory / "example"
            source.write_text("int helper(int n) { return n + 211; }\nint main(void) { return helper(4); }\n")
            cls.run_command([CLANG, "--target=" + architecture + "-apple-macos11", "-g", "-c", str(source), "-o", str(object_file)])
            cls.run_command(fixture_link_command(binary, [object_file], architecture))
            bundle = directory / "example.dSYM"
            cls.run_command([DSYMUTIL, str(binary), "-o", str(bundle)])
            cls.thin[architecture] = (binary, bundle, object_file)
        cls.fat = cls.fat_fixture / "example"
        cls.run_command([LIPO, "-create", *[str(values[0]) for values in cls.thin.values()], "-output", str(cls.fat)])
        cls.stripped = cls.fat_fixture / "stripped"
        cls.run_command([MACHO_STRIP, "-S", "-o", str(cls.stripped), str(cls.fat)])

    def setUp(self):
        super().setUp()
        if sys.platform != "darwin":
            # LLVM dsymutil discovers lipo by its Apple command name.
            directory = self.root / "fixture-bin"
            directory.mkdir()
            (directory / "lipo").symlink_to(LIPO)
            patcher = mock.patch.dict(os.environ, {"PATH": str(directory) + os.pathsep + os.environ.get("PATH", "")})
            patcher.start()
            self.addCleanup(patcher.stop)

    def install_fat(self, target="example", *, existing=(), products_source=False):
        runtime = self.app / ("Contents/Frameworks/" + target + ".framework/Versions/A/" + target)
        runtime.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.stripped, runtime)
        shutil.rmtree(self.products / (target + ".dSYM"), ignore_errors=True)
        for architecture in existing:
            shutil.copytree(self.thin[architecture][1], self.products / (target + "-" + architecture + ".dSYM"))
        if products_source:
            source = self.products / "unstripped" / target
            source.parent.mkdir(exist_ok=True)
            shutil.copyfile(self.fat, source)
        write_inventory(self.build, self.app, "Release", ["pods"], [
            {"target": "rust_api", "product": "rust_api.framework", "source": "pods"},
            {"target": "example", "product": "example.framework", "source": "pods"},
        ])
        return runtime

    def report(self):
        return json.loads((self.build / "macos/sentry-symbol-preparation.json").read_text())

    def test_universal_runtime_pairs_two_separate_thin_dsyms_and_real_cli_audit(self):
        self.install_fat(existing=("arm64", "x86_64"))
        manifest = json.loads(self.prepare().read_text())
        entries = [entry for entry in manifest["artifacts"] if entry["target"] == "example"]
        self.assertEqual({entry["architecture"] for entry in entries}, {"arm64", "x86_64"})
        self.assertEqual(len({entry["debug_file"] for entry in entries}), 2)
        self.assertTrue(all(len(variants(self.build / entry["debug_file"])) == 1 for entry in entries))
        if CLI:
            import upload_sentry_symbols as upload
            _, evidence, _ = upload.audit_macos(CLI, self.build)
            self.assertEqual({entry["architecture"] for entry in evidence if entry["target"] == "example"}, {"arm64", "x86_64"})

    def test_one_slice_without_lines_is_not_hidden_by_good_sibling(self):
        self.install_fat(existing=("x86_64",))
        thin = self.root / "stripped-arm64"
        self.run_command([MACHO_STRIP, "-S", "-o", str(thin), str(self.thin["arm64"][0])])
        self.run_command([DSYMUTIL, str(thin), "-o", str(self.products / "line-less.dSYM")])
        with self.assertRaisesRegex(PreparationError, "required_macos_matching_dsym_unavailable"):
            self.prepare()
        rows = {row["architecture"]: row for row in self.report()["modules"] if row["target"] == "example"}
        self.assertTrue(rows["x86_64"]["ready"])
        self.assertFalse(rows["arm64"]["ready"])
        self.assertEqual(rows["arm64"]["existing_uuid_matches"], 1)
        self.assertEqual(rows["arm64"]["existing_debug_line_matches"], 0)
        self.assertFalse((self.build / "sentry-native/macos/manifest.json").exists())

    def test_stripped_final_recovers_matching_products_source_once_for_both_slices(self):
        runtime = self.install_fat(products_source=True)
        self.assertFalse(any(item["has_oso_symbols"] for item in variants(runtime)))
        with mock.patch.object(preparation, "run_dsymutil", wraps=preparation.run_dsymutil) as run:
            self.prepare()
        self.assertEqual(run.call_count, 1)
        rows = [row for row in self.report()["modules"] if row["target"] == "example"]
        self.assertTrue(all(row["ready"] and row["origin"] == "generated_products_oso" for row in rows))
        self.assertEqual(self.report()["counts"]["dsymutil_runs"], 1)
        if CLI:
            import upload_sentry_symbols as upload
            upload.audit_macos(CLI, self.build)

    def test_wrong_uuid_and_same_uuid_different_code_sources_are_rejected(self):
        self.install_fat(products_source=True)
        source = self.products / "unstripped/example"
        shutil.copyfile(self.modules["runner"][0], source)
        with self.assertRaisesRegex(PreparationError, "required_macos_matching_dsym_unavailable"):
            self.prepare()
        self.assertTrue(all(row["products_oso_matches"] == 0 for row in self.report()["modules"] if row["target"] == "example"))
        shutil.copyfile(self.fat, source)
        with source.open("r+b") as stream:
            for item in read_slices(source):
                section = next(section for section in item["sections"] if section["name"] == "__text")
                stream.seek(section["offset"])
                byte = stream.read(1)
                stream.seek(section["offset"])
                stream.write(bytes([byte[0] ^ 1]))
        with self.assertRaisesRegex(PreparationError, "required_macos_matching_dsym_unavailable"):
            self.prepare()
        self.assertTrue(all(row["products_code_mismatches"] == 1 for row in self.report()["modules"] if row["target"] == "example"))

    def test_native_asset_source_promotes_all_actual_slices_to_required(self):
        self.install_fat("objective_c", products_source=True)
        manifest = json.loads(self.prepare().read_text())
        self.assertEqual({entry["architecture"] for entry in manifest["required"] if entry["target"] == "objective_c"},
                         {"arm64", "x86_64"})
        self.assertTrue(all(row["source"] == "prebuilt" and row["products_promoted_module"] and row["ready"]
                            for row in self.report()["modules"] if row["target"] == "objective_c"))
        if CLI:
            import upload_sentry_symbols as upload
            upload.audit_macos(CLI, self.build)
        shutil.copyfile(self.thin["x86_64"][0], self.products / "unstripped/objective_c")
        with self.assertRaisesRegex(PreparationError, "required_macos_matching_dsym_unavailable"):
            self.prepare()
        rows = [row for row in self.report()["modules"] if row["target"] == "objective_c"]
        self.assertTrue(all(row["required"] and row["products_promoted_module"] for row in rows))
        self.assertEqual({row["architecture"] for row in rows if not row["ready"]}, {"arm64"})

    def test_rust_language_evidence_is_required_in_each_actual_slice(self):
        self.install_fat("rust_api", existing=("arm64", "x86_64"))
        # Keep the per-slice rule deterministic. Real reader/process behavior
        # has independent no-compiler coverage in sentry_macos_reader_test.py.
        def evidence(_tool, _path, *, architecture, **_kwargs):
            return architecture == "x86_64"
        with mock.patch.object(preparation, "contains_rust_debug", side_effect=evidence) as reader, \
             self.assertRaisesRegex(PreparationError, "^rust_framework_missing_rust_compilation_units$"):
            Preparer(self.build, dsymutil=DSYMUTIL, dwarfdump="fixture-dwarfdump").prepare()
        self.assertEqual({call.kwargs["architecture"] for call in reader.call_args_list}, {"arm64", "x86_64"})
        rows = {row["architecture"]: row for row in self.report()["modules"] if row["target"] == "rust_api"}
        self.assertTrue(rows["x86_64"]["ready"])
        self.assertFalse(rows["arm64"]["ready"])
        self.assertTrue(all(row["rust_cu_checked"] for row in rows.values()))

    @unittest.skipUnless(ARCHIVER, "Real static archive fixture requires ar")
    def test_products_optional_static_archive_is_classified_but_corruption_fails(self):
        self.install_fat(products_source=True)
        archives = []
        for architecture, values in self.thin.items():
            archive = self.root / (architecture + ".a")
            self.run_command([ARCHIVER, "rcs", str(archive), str(values[2])])
            archives.append(archive)
        static = self.products / "static/example"
        static.parent.mkdir()
        self.run_command([LIPO, "-create", *map(str, archives), "-output", str(static)])
        self.prepare()
        static.write_bytes(static.read_bytes()[:-17])
        with self.assertRaisesRegex(PreparationError, "invalid_macos_source_image"):
            self.prepare()


@unittest.skipUnless(shutil.which("go"), "Go cross-compilation fixture unavailable")
class GoDsymGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix="sentry-go-dsym-fixtures-")
        cls.addClassCleanup(cls.shared.cleanup)
        cls.root = Path(cls.shared.name).resolve()
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
        self.output = Path(self.temporary.name).resolve()

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
