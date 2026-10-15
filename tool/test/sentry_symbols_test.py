#!/usr/bin/env python3
"""Symbol upload contract tests plus a real MSVC PE/PDB check on Windows.

The native test requires CMake, Visual Studio C++, and sentry-cli 2.58.4. It
compiles the production CMake symbol rules, then checks actual PE/PDB debug IDs.
All tests are offline: upload requests are intercepted, never sent to Sentry.
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "upload_sentry_symbols.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("sentry_symbols", SCRIPT)
symbols = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(symbols)
DEBUG_ID = "12345678-1234-1234-1234-123456789abc-1"
OTHER_ID = "87654321-1234-1234-1234-123456789abc-1"


class SymbolAuditTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xflclash-symbol-audit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.native = self.build / "windows/x64"
        self.manifest = self.native / "sentry-symbols/Release/targets.tsv"
        self.manifest.parent.mkdir(parents=True)
        self.records = []
        self.metadata = {}
        self.calls = []
        for name in ("FlClash", "flutter_inappwebview_windows_plugin", "desktop_webview_window_plugin"):
            binary = self.native / "runner/Release" / (name + (".exe" if name == "FlClash" else ".dll"))
            pdb = self.manifest.parent / (name + ".pdb")
            for path in (binary, pdb):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture " + path.name)
                self.metadata[str(path)] = self.info("pdb" if path == pdb else "pe")
            self.records.append([name, str(binary), str(pdb)])
        self.write_manifest()
        dart = self.build / "debug-info/app.windows-x64.symbols"
        dart.parent.mkdir()
        dart.write_text("fixture Dart debug info")
        self.metadata[str(dart)] = self.info("elf")

    def info(self, kind, debug_id=DEBUG_ID, features="symtab, debug"):
        return {"type": kind, "variants": [{"debug_id": debug_id}],
                "features": features, "is_usable": True}

    def write_manifest(self):
        self.manifest.write_text("".join("\t".join(row) + "\n" for row in self.records))

    def cli(self, executable, arguments):
        self.calls.append(arguments)
        if arguments == ["--version"]:
            return "sentry-cli 2.58.4\n"
        if arguments[:2] == ["debug-files", "check"]:
            return json.dumps(self.metadata[arguments[-1]])
        self.assertEqual(arguments[:2], ["debug-files", "upload"])
        stage = Path(arguments[-1])
        staged = [path for path in stage.rglob("*") if path.is_file()]
        self.assertEqual(len(staged), 4)
        self.assertTrue(all(path.suffix in (".pdb", ".symbols") for path in staged))
        self.assertIn("--no-sources", arguments)
        self.assertIn("--no-zips", arguments)
        self.assertIn("--wait-for", arguments)
        self.assertIn("--require-all", arguments)
        self.assertIn("--id", arguments)
        self.assertNotIn("--include-sources", arguments)
        return "processed"

    def run_main(self, *, token="", platform="windows", audit_only=False):
        evidence = self.build / "evidence.json"
        argv = ["--platform", platform, "--flavor", "brand_a", "--build-root", str(self.build),
                "--evidence", str(evidence)]
        if audit_only:
            argv.append("--audit-only")
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
             mock.patch.object(symbols.shutil, "which", return_value="fake-sentry-cli"), \
             mock.patch.dict(os.environ, {"SENTRY_AUTH_TOKEN": token}, clear=False):
            result = symbols.main(argv)
        data = json.loads(evidence.read_text())
        self.assertNotIn(str(self.root), evidence.read_text())
        if token:
            self.assertNotIn(token, evidence.read_text())
        return result, data

    def test_matching_all_native_targets_and_dart_upload(self):
        result, evidence = self.run_main(token="secret-sentry-token")
        self.assertEqual(result, 0)
        self.assertEqual(evidence["status"], "uploaded_and_processed")
        self.assertEqual(len(evidence["native"]), 3)

    def test_offline_audit_never_uploads(self):
        result, evidence = self.run_main(audit_only=True)
        self.assertEqual(result, 0)
        self.assertEqual(evidence["status"], "audited")
        self.assertFalse(any(call[:2] == ["debug-files", "upload"] for call in self.calls))

    def test_windows_missing_token_fails(self):
        result, evidence = self.run_main()
        self.assertEqual(result, 1)
        self.assertEqual(evidence["status"], "failed")

    def test_other_platform_missing_token_is_explicit_skip(self):
        dart = self.build / "debug-info/app.android-arm64.symbols"
        dart.write_text("fixture Android debug info")
        self.metadata[str(dart)] = self.info("elf")
        native_evidence = [{"target": "libcore.so", "architecture": "arm64-v8a", "source": "cmake",
                            "debug_ids": [DEBUG_ID]}]
        with mock.patch.object(symbols, "audit_elf_native", return_value=([], native_evidence, [])):
            result, evidence = self.run_main(platform="android")
        self.assertEqual(result, 0)
        self.assertEqual(evidence["status"], "skipped_missing_token")
        self.assertEqual(evidence["native_coverage"], "explicit_manifest_audited")
        self.assertEqual(evidence["native"], native_evidence)

    def test_mismatching_pdb_fails(self):
        self.metadata[self.records[1][2]]["variants"][0]["debug_id"] = OTHER_ID
        self.assertEqual(self.run_main(token="secret")[0], 1)

    def test_missing_pdb_fails(self):
        Path(self.records[1][2]).unlink()
        self.assertEqual(self.run_main(token="secret")[0], 1)

    def test_missing_tutorial_target_fails(self):
        self.records.pop(1)
        self.write_manifest()
        self.assertEqual(self.run_main(token="secret")[0], 1)

    def test_pdb_without_line_information_fails(self):
        self.metadata[self.records[1][2]]["features"] = "symtab"
        self.assertEqual(self.run_main(token="secret")[0], 1)

    def test_macos_collects_darwin_dart_companions_and_dsym(self):
        expected = []
        for architecture in ("x86_64", "arm64"):
            path = self.build / f"debug-info/app.darwin-{architecture}.symbols"
            path.write_text("fixture Darwin debug information")
            self.metadata[str(path)] = self.info("elf")
            expected.append(path)
        dwarf = self.build / "macos/Build/Products/Release/App.framework.dSYM/Contents/Resources/DWARF/App"
        dwarf.parent.mkdir(parents=True)
        dwarf.write_text("fixture dSYM")
        self.metadata[str(dwarf)] = self.info("dsym")
        expected.append(dwarf)
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli):
            artifacts, _ = symbols.collect_companions("sentry-cli", self.build, "macos")
        self.assertCountEqual(artifacts, expected)
        self.assertFalse(any("windows" in artifact.name for artifact in artifacts))

    def test_artifact_outside_build_root_fails(self):
        self.records[1][2] = str(self.root / "outside.pdb")
        self.write_manifest()
        self.assertEqual(self.run_main(token="secret")[0], 1)

    def test_no_manifest_fails(self):
        self.manifest.unlink()
        self.assertEqual(self.run_main(token="secret")[0], 1)

    def test_stale_installed_plugin_fails(self):
        original_binary = Path(self.records[1][1])
        linked_binary = self.native / "plugins/Release" / original_binary.name
        linked_binary.parent.mkdir(parents=True)
        shutil.copyfile(original_binary, linked_binary)
        original_binary.write_text("stale bundled plugin")
        self.records[1][1] = str(linked_binary)
        self.metadata[str(linked_binary)] = self.info("pe")
        self.write_manifest()
        self.assertEqual(self.run_main(token="secret")[0], 1)

    def test_upload_failure_cannot_be_reported_as_success(self):
        original = self.cli
        def fail_upload(executable, arguments):
            if arguments[:2] == ["debug-files", "upload"]:
                raise symbols.SymbolError("simulated processing failure")
            return original(executable, arguments)
        self.cli = fail_upload
        result, evidence = self.run_main(token="secret")
        self.assertEqual(result, 1)
        self.assertEqual(evidence["status"], "failed")


class CliMetadataTest(unittest.TestCase):
    def test_pe_without_embedded_debug_is_valid_for_pdb_matching(self):
        metadata = {"type": "pe", "variants": [{"debug_id": DEBUG_ID}],
                    "features": "none", "is_usable": False}
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "fixture.exe"
            binary.write_bytes(b"fixture")
            response = subprocess.CompletedProcess([], 1, stdout=json.dumps(metadata), stderr="")
            with mock.patch.object(symbols.subprocess, "run", return_value=response):
                info = symbols.check_symbol("sentry-cli", binary, "pe")
            self.assertEqual(info["debug_ids"], [DEBUG_ID])

    def test_unusable_pdb_cannot_be_uploaded(self):
        metadata = {"type": "pdb", "variants": [{"debug_id": DEBUG_ID}],
                    "features": "none", "is_usable": False}
        with tempfile.TemporaryDirectory() as temporary:
            pdb = Path(temporary) / "fixture.pdb"
            pdb.write_bytes(b"fixture")
            response = subprocess.CompletedProcess([], 1, stdout=json.dumps(metadata), stderr="")
            with mock.patch.object(symbols.subprocess, "run", return_value=response), \
                 self.assertRaises(symbols.SymbolError):
                symbols.check_symbol("sentry-cli", pdb, "pdb")

    def test_cli_failure_does_not_echo_raw_stderr_or_credentials(self):
        response = subprocess.CompletedProcess([], 1, stdout="", stderr="DSN secret-token C:/sensitive/env.json")
        with mock.patch.object(symbols.subprocess, "run", return_value=response), \
             self.assertRaises(symbols.SymbolError) as caught:
            symbols.run_cli("sentry-cli", ["debug-files", "upload", "/safe/stage"])
        self.assertNotIn("secret-token", str(caught.exception))
        self.assertNotIn("env.json", str(caught.exception))


@unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("gcc") and shutil.which("objcopy"),
                     "Real ELF fixture needs Linux gcc and objcopy")
class NativeElfSymbolsTest(unittest.TestCase):
    """Exercise actual ELF files, strip operations and companion identifiers."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xflclash-native-elf-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.native = self.build / "sentry-native/linux"
        self.native.mkdir(parents=True)
        self.architecture = "arm64" if platform.machine().lower() in ("aarch64", "arm64") else "x64"
        self.binary = self.build / f"linux/{self.architecture}/release/bundle/FlClash"
        self.binary.parent.mkdir(parents=True)
        self.source = self.root / "fixture.c"
        self.source.write_text("int fixture_add(int value) { return value + 19; }\n")
        self.original = self.native / "source.so"
        subprocess.run(["gcc", "-g", "-O2", "-fPIC", "-shared", "-Wl,--build-id=sha1",
                        str(self.source), "-o", str(self.original)], check=True, capture_output=True)
        self.debug = self.native / "FlClash.debug"
        subprocess.run(["objcopy", "--only-keep-debug", str(self.original), str(self.debug)],
                       check=True, capture_output=True)
        for index, name in enumerate(symbols.inspect_elf(self.original)["unwind_sections"]):
            contents = self.root / f"unwind-{index}"
            subprocess.run(["objcopy", "--dump-section", f"{name}={contents}", str(self.original)],
                           check=True, capture_output=True)
            subprocess.run(["objcopy", "--set-section-flags", f"{name}=alloc,load,readonly,data,contents", str(self.debug)],
                           check=True, capture_output=True)
            subprocess.run(["objcopy", "--update-section", f"{name}={contents}", str(self.debug)],
                           check=True, capture_output=True)
        shutil.copyfile(self.original, self.binary)
        subprocess.run(["objcopy", "--strip-debug", str(self.binary)], check=True, capture_output=True)
        self.manifest = {"schema_version": 1, "platform": "linux", "artifacts": [{
            "target": "FlClash", "architecture": self.architecture, "source": "cmake",
            "binary": self.binary.relative_to(self.build).as_posix(),
            "debug_file": self.debug.relative_to(self.build).as_posix(),
        }], "limitations": [{"target": "FlClashCore", "architecture": self.architecture, "source": "go",
                              "reason": "separate_process_no_sentry_sdk"}]}
        self.rust_binary = self.binary.parent / "lib/librust_api.so"
        self.rust_binary.parent.mkdir()
        shutil.copyfile(self.binary, self.rust_binary)
        self.rust_debug = self.native / "librust_api.so.debug"
        shutil.copyfile(self.debug, self.rust_debug)
        self.manifest["artifacts"].append({
            "target": "librust_api.so", "architecture": self.architecture, "source": "rust",
            "binary": self.rust_binary.relative_to(self.build).as_posix(),
            "debug_file": self.rust_debug.relative_to(self.build).as_posix(),
        })
        self.manifest["required"] = [{"target": entry["target"], "architecture": entry["architecture"]}
                                     for entry in self.manifest["artifacts"]]
        self.cmake_source = self.binary.parent.parent / "intermediates/FlClash"
        self.cmake_source.parent.mkdir()
        shutil.copyfile(self.original, self.cmake_source)
        self.cmake_map = self.binary.parent.parent / "sentry-native-Release.tsv"
        self.cmake_map.write_text(f"FlClash\t{self.cmake_source}\n")
        self.write_manifest()
        self.calls = []

    def write_manifest(self):
        (self.native / "manifest.json").write_text(json.dumps(self.manifest))

    def cli(self, executable, arguments):
        self.calls.append(arguments)
        if arguments == ["--version"]:
            return "sentry-cli 2.58.4\n"
        if arguments[:2] == ["debug-files", "check"]:
            path = Path(arguments[-1])
            unwind = path.suffix != ".symbols" and bool(symbols.inspect_elf(path)["unwind_sections"])
            return json.dumps({"type": "elf", "variants": [{"debug_id": DEBUG_ID}],
                               "features": "symtab, debug" + (", unwind" if unwind else ""), "is_usable": True})
        if arguments[:2] == ["debug-files", "upload"]:
            staged = [p for p in Path(arguments[-1]).rglob("*") if p.is_file()]
            self.assertEqual({p.suffix for p in staged}, {".debug", ".symbols"})
            self.assertFalse(any(symbols.inspect_elf(p)["has_executable_text"] for p in staged if p.suffix == ".debug"))
            self.assertNotIn(self.source.name, {p.name for p in staged})
            self.assertNotIn("--include-sources", arguments)
            return "processed"
        self.fail("Unexpected CLI call")

    def audit(self):
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli):
            return symbols.audit_elf_native("sentry-cli", self.build, "linux")

    def test_real_parser_distinguishes_companion_from_executable_and_stripped_binary(self):
        original, binary, debug = (symbols.inspect_elf(path) for path in (self.original, self.binary, self.debug))
        self.assertEqual(original["build_id"], debug["build_id"])
        self.assertEqual(binary["build_id"], debug["build_id"])
        self.assertTrue(original["has_debug_info"] and original["has_debug_line"])
        self.assertFalse(binary["has_debug_info"])
        self.assertTrue(binary["has_executable_text"])
        self.assertFalse(debug["has_executable_text"])
        artifacts, evidence, limitations = self.audit()
        self.assertEqual(artifacts, [self.debug, self.rust_debug])
        self.assertEqual(evidence[0]["build_id"], original["build_id"])
        self.assertEqual(limitations[0]["reason"], "separate_process_no_sentry_sdk")

    def test_real_cli_accepts_matching_elf_and_debug_companion(self):
        cli = shutil.which("sentry-cli")
        if not cli:
            self.skipTest("Pinned sentry-cli is not installed")
        self.assertEqual(symbols.run_cli(cli, ["--version"]).strip(), "sentry-cli 2.58.4")
        artifacts, evidence, _ = symbols.audit_elf_native(cli, self.build, "linux")
        self.assertEqual(artifacts, [self.debug, self.rust_debug])
        self.assertIn("debug", evidence[0]["features"])

    def test_production_preparer_companions_pass_real_cli_audit(self):
        cli = shutil.which("sentry-cli")
        if not cli:
            self.skipTest("Pinned sentry-cli is not installed")
        from prepare_sentry_native_symbols import Preparer
        source = self.root / "unstripped.so"
        shutil.copyfile(self.original, source)
        prepare = Preparer(self.build, "linux", "objcopy")
        prepare.add("FlClash", self.architecture, self.binary, [source], "cmake", True)
        prepare.add("librust_api.so", self.architecture, self.rust_binary, [source], "rust", True)
        prepare.finish()
        artifacts, evidence, _ = symbols.audit_elf_native(cli, self.build, "linux")
        self.assertEqual(len(artifacts), 2)
        self.assertTrue(all("debug" in entry["features"] and "unwind" in entry["features"] for entry in evidence))

    def test_renamed_release_binary_is_never_uploadable(self):
        shutil.copyfile(self.binary, self.debug)
        with self.assertRaisesRegex(symbols.SymbolError, "executable code"):
            self.audit()

    def test_missing_dwarf_line_section_fails(self):
        subprocess.run(["objcopy", "--remove-section=.debug_line", str(self.debug)], check=True, capture_output=True)
        with self.assertRaisesRegex(symbols.SymbolError, "DWARF line information"):
            self.audit()

    def test_companion_without_original_unwind_information_fails(self):
        subprocess.run(["objcopy", "--only-keep-debug", str(self.original), str(self.debug)],
                       check=True, capture_output=True)
        with self.assertRaisesRegex(symbols.SymbolError, "unwind information"):
            self.audit()

    def test_mismatching_actual_elf_build_id_fails(self):
        self.source.write_text("int fixture_other(int value) { return value + 887; }\n")
        subprocess.run(["gcc", "-g", "-fPIC", "-shared", "-Wl,--build-id=sha1", str(self.source),
                        "-o", str(self.original)], check=True, capture_output=True)
        subprocess.run(["objcopy", "--only-keep-debug", str(self.original), str(self.debug)], check=True, capture_output=True)
        with self.assertRaisesRegex(symbols.SymbolError, "build identifier mismatch"):
            self.audit()

    def test_cli_debug_id_mismatch_fails_even_with_matching_build_id(self):
        original = self.cli
        def mismatch(executable, arguments):
            result = original(executable, arguments)
            if arguments[-1] == str(self.debug):
                return result.replace(DEBUG_ID, OTHER_ID)
            return result
        self.cli = mismatch
        with self.assertRaisesRegex(symbols.SymbolError, "debug identifier mismatch"):
            self.audit()

    def test_manifest_architecture_mismatch_fails(self):
        self.manifest["artifacts"][0]["architecture"] = "arm64" if self.architecture == "x64" else "x64"
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "architecture mismatch"):
            self.audit()

    def test_relative_path_traversal_and_symlink_escape_fail(self):
        outside = self.root / "outside.debug"
        shutil.copyfile(self.debug, outside)
        for value in ("../outside.debug", "sentry-native/linux/outside.debug"):
            symlink = self.native / "outside.debug"
            if not symlink.exists():
                symlink.symlink_to(outside)
            self.manifest["artifacts"][0]["debug_file"] = value
            self.write_manifest()
            with self.subTest(value=value), self.assertRaisesRegex(symbols.SymbolError, "escaped"):
                self.audit()

    def test_duplicate_target_architecture_is_rejected(self):
        self.manifest["artifacts"].append(dict(self.manifest["artifacts"][0]))
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "Duplicate"):
            self.audit()

    def test_no_native_manifest_cannot_be_reported_as_covered(self):
        (self.native / "manifest.json").unlink()
        with self.assertRaisesRegex(symbols.SymbolError, "native symbol manifest"):
            self.audit()

    def test_truncated_artifact_list_cannot_hide_a_required_module(self):
        self.manifest["artifacts"].pop()
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "omitted a required"):
            self.audit()

    def test_truncated_required_list_cannot_hide_mandatory_owned_modules(self):
        self.manifest["artifacts"].pop()
        self.manifest["required"].pop()
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "mandatory owned module"):
            self.audit()

    def test_android_static_owned_module_guard_rejects_truncated_manifest(self):
        from prepare_sentry_native_symbols import Preparer
        source = self.root / "unstripped.so"
        shutil.copyfile(self.original, source)
        abi = "arm64-v8a" if self.architecture == "arm64" else "x86_64"
        prepare = Preparer(self.build, "android", "objcopy")
        for target in ("libcore.so", "libclash.so", "librust_api.so"):
            binary = prepare.output / "runtime/0" / abi / target
            binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.binary, binary)
            prepare.add(target, abi, binary, [source], "fixture", True)
        shutil.copyfile(self.binary, binary.parent / "libflutter.so")
        manifest_path = prepare.finish()
        manifest = json.loads(manifest_path.read_text())
        manifest["artifacts"] = [entry for entry in manifest["artifacts"] if entry["target"] != "libcore.so"]
        manifest["required"] = [entry for entry in manifest["required"] if entry["target"] != "libcore.so"]
        manifest_path.write_text(json.dumps(manifest))
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
             self.assertRaisesRegex(symbols.SymbolError, "mandatory owned module"):
            symbols.audit_elf_native("sentry-cli", self.build, "android")

    def test_android_entire_abi_cannot_disappear_from_both_manifest_lists(self):
        from prepare_sentry_native_symbols import Preparer
        source = self.root / "unstripped.so"
        shutil.copyfile(self.original, source)
        abi = "arm64-v8a" if self.architecture == "arm64" else "x86_64"
        omitted_abi = "x86_64" if abi != "x86_64" else "arm64-v8a"
        prepare = Preparer(self.build, "android", "objcopy")
        for target in ("libcore.so", "libclash.so", "librust_api.so"):
            binary = prepare.output / "runtime/0" / abi / target
            binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.binary, binary)
            prepare.add(target, abi, binary, [source], "fixture", True)
        shutil.copyfile(self.binary, binary.parent / "libflutter.so")
        prepare.finish()
        # A second final APK inventory remains after every upload-list record
        # for that ABI is absent. The audit must inspect the inventory itself.
        other = prepare.output / "runtime/1" / omitted_abi
        other.mkdir(parents=True)
        for target in ("libcore.so", "libclash.so", "librust_api.so", "libflutter.so"):
            shutil.copyfile(self.binary, other / target)
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
             self.assertRaisesRegex(symbols.SymbolError, "distributed Android ABI"):
            symbols.audit_elf_native("sentry-cli", self.build, "android")

    def test_linux_cmake_plugin_cannot_disappear_from_both_manifest_lists_or_source_map(self):
        source = self.binary.parent.parent / "plugins/example/libexample_plugin.so"
        source.parent.mkdir(parents=True)
        shutil.copyfile(self.original, source)
        runtime = self.rust_binary.parent / source.name
        shutil.copyfile(self.binary, runtime)
        debug = self.native / (source.name + ".debug")
        shutil.copyfile(self.debug, debug)
        entry = {"target": source.name, "architecture": self.architecture, "source": "cmake",
                 "binary": runtime.relative_to(self.build).as_posix(),
                 "debug_file": debug.relative_to(self.build).as_posix()}
        self.manifest["artifacts"].append(entry)
        self.manifest["required"].append({"target": source.name, "architecture": self.architecture})
        self.cmake_map.write_text(self.cmake_map.read_text() + f"example\t{source}\n")
        self.write_manifest()
        self.assertEqual(len(self.audit()[0]), 3)
        self.manifest["artifacts"].pop()
        self.manifest["required"].pop()
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "distributed CMake"):
            self.audit()
        # Removing the source-map row as well still leaves a matching, locally
        # compiled intermediate; it must not silently become a prebuilt gap.
        self.cmake_map.write_text(f"FlClash\t{self.cmake_source}\n")
        with self.assertRaisesRegex(symbols.SymbolError, "distributed CMake"):
            self.audit()

    def test_distributed_core_cannot_be_omitted_from_coverage(self):
        shutil.copyfile(self.binary, self.binary.parent / "FlClashCore")
        with self.assertRaisesRegex(symbols.SymbolError, "distributed Go core"):
            self.audit()

    def test_build_id_missing_fails(self):
        subprocess.run(["objcopy", "--remove-section=.note.gnu.build-id", str(self.binary)], check=True, capture_output=True)
        with self.assertRaisesRegex(symbols.SymbolError, "build identifier mismatch"):
            self.audit()

    def test_limitations_cannot_export_paths_or_arbitrary_text(self):
        self.manifest["limitations"][0]["reason"] = "/private/brand/config.json"
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "manifest reason"):
            self.audit()

    def test_upload_stages_only_companions_and_keeps_safe_native_evidence(self):
        dart = self.build / f"debug-info/app.linux-{self.architecture}.symbols"
        dart.parent.mkdir()
        dart.write_text("fake split debug info")
        evidence_file = self.build / "evidence.json"
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
             mock.patch.object(symbols.shutil, "which", return_value="fake-cli"), \
             mock.patch.dict(os.environ, {"SENTRY_AUTH_TOKEN": "fixture-secret"}):
            result = symbols.main(["--platform", "linux", "--flavor", "brand_a", "--build-root", str(self.build),
                                   "--evidence", str(evidence_file)])
        self.assertEqual(result, 0)
        evidence = json.loads(evidence_file.read_text())
        self.assertEqual(evidence["native_coverage"], "explicit_manifest_audited")
        self.assertEqual(evidence["native"][0]["architecture"], self.architecture)
        self.assertEqual(evidence["native_limitations"], self.manifest["limitations"])
        self.assertNotIn(str(self.root), evidence_file.read_text())
        self.assertNotIn("fixture-secret", evidence_file.read_text())


@unittest.skipUnless(os.name != "nt" and shutil.which("bash"), "Local shell entrypoint checks use POSIX bash")
class LocalUploadEntrypointTest(unittest.TestCase):
    def run_android_block(self, token="", token_file=False, upload_exit=0, mode="release"):
        script = (SCRIPT.parents[1] / "scripts/build_local.sh").read_text()
        block = script.split("# === Sentry 符号上传（仅 release；NFR-7）===", 1)[1].split("# === 自动部署", 1)[0]
        with tempfile.TemporaryDirectory(prefix="xflclash-upload-shell-") as temporary:
            root = Path(temporary)
            tools = root / "bin"
            tools.mkdir()
            (tools / "git").write_text("#!/usr/bin/env bash\nprintf '123456789abcdef\\n'\n")
            (tools / "python3").write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$SENTRY_TEST_ARGV"\nexit "$SENTRY_TEST_EXIT_CODE"\n')
            for path in tools.iterdir():
                path.chmod(0o700)
            if token_file:
                (root / "flavors").mkdir()
                (root / "flavors/sentry-cli.token").write_text("fixture-file-token\n")
            log = root / "arguments.txt"
            env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                   "SENTRY_AUTH_TOKEN": token, "SENTRY_TEST_ARGV": str(log),
                   "SENTRY_TEST_EXIT_CODE": str(upload_exit)}
            setup = f'set -euo pipefail\nMODE={mode}\nFLAVOR=brand_a\nVERSION_NAME=0.0.1\nBUILD_NUMBER=14\n'
            result = subprocess.run(["bash", "-c", setup + block], env=env, cwd=root,
                                    capture_output=True, text=True, timeout=10)
            output = result.stdout + result.stderr
            self.assertNotIn("fixture-file-token", output)
            if token:
                self.assertNotIn(token, output)
            return result.returncode, output, log.read_text() if log.exists() else None

    def test_android_missing_token_is_explicit_skip(self):
        code, output, arguments = self.run_android_block()
        self.assertEqual(code, 0)
        self.assertIn("明确跳过", output)
        self.assertIsNone(arguments)

    def test_android_token_file_calls_safe_uploader(self):
        code, _, arguments = self.run_android_block(token_file=True)
        self.assertEqual(code, 0)
        self.assertIn("tool/upload_sentry_symbols.py\n--platform\nandroid", arguments)
        self.assertNotIn("--include-sources", arguments)

    def test_android_upload_failure_blocks_entrypoint(self):
        self.assertEqual(self.run_android_block(token="fixture-env-token", upload_exit=7)[0], 7)

    def test_debug_does_not_upload(self):
        code, _, arguments = self.run_android_block(token="fixture-env-token", mode="debug")
        self.assertEqual(code, 0)
        self.assertIsNone(arguments)

    @unittest.skipUnless(shutil.which("jq"), "jq is required for package config logging")
    def test_config_logging_never_prints_private_values(self):
        for relative in (".github/workflows/release-package.yml", "scripts/package_desktop_local.sh"):
            text = (SCRIPT.parents[1] / relative).read_text()
            line = next(line.strip() for line in text.splitlines()
                        if line.strip().startswith("jq -r 'keys | join"))
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "env.json").write_text(json.dumps({"XB_AES_KEY_B64": "fixture-private-aes",
                    "XB_SENTRY_DSN": "fixture-private-dsn", "NEW_PRIVATE_DEFINE": "fixture-other-private"}))
                result = subprocess.run(["bash", "-c", line], cwd=root, capture_output=True,
                                        text=True, check=True, timeout=10)
                self.assertIn("XB_SENTRY_DSN", result.stdout)
                self.assertNotIn("fixture-private", result.stdout)
                self.assertNotIn("fixture-other-private", result.stdout)


@unittest.skipUnless(os.name == "nt", "Actual MSVC/PDB generation requires Windows")
class NativeWindowsSymbolsTest(unittest.TestCase):
    def test_production_rules_generate_matching_pdb_for_runner_and_plugins(self):
        # Native CI test, not a string assertion about compiler/linker flags.
        from windows_loader_install_test import find_cmake
        cli = shutil.which("sentry-cli")
        self.assertIsNotNone(cli, "CI must install sentry-cli before this test")
        with tempfile.TemporaryDirectory(prefix="xflclash-msvc-symbols-") as temporary:
            root = Path(temporary)
            source, build = root / "source with spaces", root / "build with spaces"
            source.mkdir()
            rules = SCRIPT.parents[1] / "windows/xboard_sentry_symbols.cmake"
            (source / "CMakeLists.txt").write_text('''cmake_minimum_required(VERSION 3.14)
project(symbol_fixture LANGUAGES CXX)
add_library(wrapper STATIC wrapper.cpp)
add_executable(FlClash main.cpp)
target_link_libraries(FlClash PRIVATE wrapper)
add_library(flutter_inappwebview_windows_plugin SHARED plugin.cpp)
add_library(desktop_webview_window_plugin SHARED plugin.cpp)
include("''' + rules.as_posix() + '''")
''')
            (source / "wrapper.cpp").write_text("int fixture_wrapper() { return 7; }\n")
            (source / "main.cpp").write_text("int fixture_wrapper(); int main() { return fixture_wrapper(); }\n")
            (source / "plugin.cpp").write_text('__declspec(dllexport) int fixture_plugin() { return 9; }\n')
            for args in (["-S", str(source), "-B", str(build)],
                         ["--build", str(build), "--config", "Release"]):
                subprocess.run([find_cmake(), *args], check=True, capture_output=True, timeout=180)
            files, evidence = symbols.audit_windows(cli, build)
            self.assertEqual(len(files), 3)
            self.assertEqual({item["target"] for item in evidence},
                             {"FlClash", "flutter_inappwebview_windows_plugin", "desktop_webview_window_plugin"})
            self.assertTrue(all("debug" in item["features"] for item in evidence))
            self.assertTrue(all(path.parent == build / "sentry-symbols/Release" for path in files))
            self.assertFalse(any(path.parent == build / "Release" for path in files))


if __name__ == "__main__":
    unittest.main(verbosity=2)
