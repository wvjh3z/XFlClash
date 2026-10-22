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
import struct
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


def elf_fixture(*, architecture="x86_64", debug=True, executable=False, build_id="1234567890abcdef1234567890abcdef12345678"):
    """Portable section/ID fixture for mocked-CLI tests, never executed."""
    strings = b"\0.shstrtab\0.note.gnu.build-id\0.debug_info\0.debug_line\0.text\0"
    note = struct.pack("<III", 4, 20, 3) + b"GNU\0" + bytes.fromhex(build_id)
    records = [(b".shstrtab", 3, 0, strings), (b".note.gnu.build-id", 7, 0, note)]
    if debug:
        records.extend([(b".debug_info", 1, 0, b"i" * 16), (b".debug_line", 1, 0, b"l" * 16)])
    records.append((b".text", 1 if executable else 8, 6, b"\x90\x90\xc3\0"))
    payload, headers = bytearray(), [b"\0" * 64]
    for name, kind, flags, data in records:
        offset = 64 + len(payload) if kind != 8 else 0
        headers.append(struct.pack("<IIQQQQIIQQ", strings.index(name + b"\0"), kind, flags, 0,
                                   offset, len(data), 0, 0, 1, 0))
        if kind != 8:
            payload.extend(data)
    header = struct.pack("<16sHHIQQQIHHHHHH", b"\x7fELF\x02\x01\x01" + b"\0" * 9, 3,
                         {"x86_64": 62, "aarch64": 183}[architecture], 1, 0, 0, 64 + len(payload),
                         0, 64, 0, 0, 64, len(headers), 1)
    return header + payload + b"".join(headers)


class SymbolAuditTest(unittest.TestCase):
    def setUp(self):
        # Upload protocol/GET behavior is covered by the real confirmation suite;
        # these tests isolate local symbol inventory and staging.
        self.confirm = mock.patch.object(symbols, "confirm_symbol_inventory", return_value=None)
        self.confirmation = self.confirm.start()
        self.addCleanup(self.confirm.stop)
        self.temporary = tempfile.TemporaryDirectory(prefix="xflclash-symbol-audit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
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
        dart.write_bytes(elf_fixture())
        self.metadata[str(dart)] = self.info("elf")
        aot = Path(self.records[0][1]).parent / "data/app.so"
        aot.parent.mkdir()
        aot.write_bytes(elf_fixture(debug=False, executable=True))
        self.metadata[str(aot)] = self.info("elf")

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
            actual = Path(arguments[-1]).resolve()
            return json.dumps(next(value for path, value in self.metadata.items() if Path(path).resolve() == actual))
        self.assertEqual(arguments[:2], ["debug-files", "upload"])
        stage = Path(arguments[-1])
        staged = [path for path in stage.rglob("*") if path.is_file()]
        self.assertEqual(len(staged), len(self.records) + 1)
        self.assertTrue(all(path.suffix in (".pdb", ".symbols") for path in staged))
        self.assertIn("--no-sources", arguments)
        self.assertIn("--no-zips", arguments)
        self.assertIn("--wait-for", arguments)
        self.assertEqual(arguments[arguments.index("--wait-for") + 1], "300")
        self.assertNotIn("--require-all", arguments)
        self.assertIn("--id", arguments)
        self.assertEqual([arguments[index + 1] for index, value in enumerate(arguments) if value == "--id"],
                         [DEBUG_ID])
        self.assertNotIn("--include-sources", arguments)
        return "> File processing complete:\n"

    def run_main(self, *, token="", platform="windows", audit_only=False, flavor="brand_a"):
        evidence = self.build / "evidence.json"
        argv = ["--platform", platform, "--flavor", flavor, "--build-root", str(self.build),
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

    @unittest.skipIf(os.name == "nt", "Directory symlink alias fixture is POSIX-only")
    def test_absolute_windows_manifest_paths_under_root_alias_are_canonicalized(self):
        alias = self.root / "build-alias"
        alias.symlink_to(self.build, target_is_directory=True)
        self.records = [[target, str(alias / Path(binary).relative_to(self.build)),
                         str(alias / Path(pdb).relative_to(self.build))]
                        for target, binary, pdb in self.records]
        self.write_manifest()
        result, evidence = self.run_main(token="fixture-token")
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

    def test_other_platform_missing_token_fails_release(self):
        dart = self.build / "debug-info/app.android-arm64.symbols"
        dart.write_bytes(elf_fixture(architecture="aarch64"))
        self.metadata[str(dart)] = self.info("elf")
        aot = self.build / "sentry-native/android/runtime/0/arm64-v8a/libapp.so"
        aot.parent.mkdir(parents=True)
        aot.write_bytes(elf_fixture(architecture="aarch64", debug=False, executable=True))
        self.metadata[str(aot)] = self.info("elf")
        native_evidence = [{"target": "librust_api.so", "architecture": "arm64-v8a", "source": "cmake",
                            "debug_ids": [DEBUG_ID]}]
        with mock.patch.object(symbols, "audit_elf_native", return_value=([], native_evidence, [])):
            result, evidence = self.run_main(platform="android")
        self.assertEqual(result, 1)
        self.assertEqual(evidence["status"], "failed")
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

    def test_distributed_windows_plugin_cannot_disappear_from_manifest(self):
        self.records.pop(2)
        self.write_manifest()
        result, evidence = self.run_main(token="fixture-token")
        self.assertEqual(result, 1)
        self.assertIn("distributed native plugin", evidence["error"])

    def test_distributed_windows_rust_cannot_disappear_from_manifest(self):
        bundle = Path(self.records[0][1]).parent
        (bundle / "rust_api.dll").write_text("fixture Rust runtime")
        result, evidence = self.run_main(token="fixture-token")
        self.assertEqual(result, 1)
        self.assertIn("Rust PDB", evidence["error"])

    def test_distributed_windows_helper_cannot_disappear_from_manifest(self):
        bundle = Path(self.records[0][1]).parent
        (bundle / "FlClashHelperService.exe").write_text("fixture helper")
        result, evidence = self.run_main(token="fixture-token")
        self.assertEqual(result, 1)
        self.assertIn("helper PDB", evidence["error"])

    def test_windows_evidence_names_external_symbols_and_independent_process_limits(self):
        bundle = Path(self.records[0][1]).parent
        for name in ("flutter_windows.dll", "WebView2Loader.dll", "FlClashCore.exe", "FlClashHelperService.exe"):
            (bundle / name).write_text("fixture external module")
        helper = bundle / "FlClashHelperService.exe"
        pdb = self.manifest.parent / "helper.pdb"
        pdb.write_text("fixture helper symbols")
        self.metadata[str(helper)] = self.info("pe")
        self.metadata[str(pdb)] = self.info("pdb")
        self.records.append(["FlClashHelperService", str(helper), str(pdb)])
        self.write_manifest()
        result, evidence = self.run_main(token="fixture-token")
        self.assertEqual(result, 0)
        reasons = {entry["target"]: entry["reason"] for entry in evidence["native_limitations"]}
        self.assertEqual(reasons["FlClashCore.exe"], "separate_process_no_sentry_sdk")
        self.assertEqual(reasons["FlClashHelperService.exe"], "separate_process_no_sentry_sdk")
        self.assertEqual(reasons["flutter_windows.dll"], "external_debug_companion_unavailable")
        self.assertEqual(reasons["WebView2Loader.dll"], "external_debug_companion_unavailable")

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

    def run_existing_server_response(self, returncode=0, stderr="", stdout=None):
        """Run the real CLI exit handling with an intercepted upload process."""
        original, real_run_cli = self.cli, symbols.run_cli

        def cli(executable, arguments):
            result = original(executable, arguments)
            if arguments[:2] == ["debug-files", "upload"]:
                return real_run_cli(executable, arguments)
            return result

        self.cli = cli
        if stdout is None:
            stdout = "> Found 4 debug information files\n> Nothing to upload, all files are on the server\n"
        response = subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)
        with mock.patch.object(symbols.subprocess, "run", return_value=response) as process:
            result, evidence = self.run_main(token="fixture-token")
        return result, evidence, process

    def test_pending_cli_exit_is_recovered_only_by_exact_confirmation(self):
        result, evidence, _ = self.run_existing_server_response(
            1, "Error: some symbols did not process correctly",
            "> File upload complete:\nThe file is still processing and not ready yet\n")
        self.assertEqual(result, 0)
        self.assertEqual(evidence["upload"]["category"], "processing_incomplete")
        self.confirmation.assert_called_once()

    def test_cli_success_cannot_override_missing_server_symbols(self):
        self.confirmation.side_effect = symbols.UploadError("symbols_unconfirmed_before_deadline", phase="confirmation")
        result, evidence, _ = self.run_existing_server_response()
        self.assertEqual(result, 1)
        self.assertEqual(evidence["status"], "failed")
        self.assertIn("symbols_unconfirmed", evidence["error"])

    def test_both_brands_confirm_their_own_project(self):
        for brand, project in (("brand_a", "omofly"), ("brand_b", "daishu")):
            self.confirmation.reset_mock()
            result, evidence = self.run_main(token="fixture-token", flavor=brand)
            self.assertEqual(result, 0)
            self.assertEqual(self.confirmation.call_args.args[0], project)

    def test_cli_timeout_has_safe_phase_diagnostics(self):
        original, real = self.cli, symbols.run_cli
        def cli(executable, arguments):
            if arguments[:2] == ["debug-files", "upload"]: return real(executable, arguments)
            return original(executable, arguments)
        self.cli = cli
        with mock.patch.object(symbols.subprocess, "run", side_effect=subprocess.TimeoutExpired("private-token", 900)):
            result, evidence = self.run_main(token="private-token")
        self.assertEqual(result, 1)
        self.assertEqual(evidence["upload"]["category"], "cli_timeout")
        self.confirmation.assert_not_called()

    def test_already_processed_server_files_complete_idempotently(self):
        result, evidence, process = self.run_existing_server_response()
        self.assertEqual(result, 0)
        self.assertEqual(evidence["status"], "uploaded_and_processed")
        process.assert_called_once()
        command = process.call_args.args[0]
        self.assertNotIn("--require-all", command)
        self.assertEqual(command[command.index("--wait-for") + 1], "300")

    def test_existing_server_files_do_not_hide_missing_local_companion(self):
        Path(self.records[1][2]).unlink()
        result, evidence, process = self.run_existing_server_response()
        self.assertEqual(result, 1)
        self.assertEqual(evidence["status"], "failed")
        process.assert_not_called()
        self.assertFalse(any(call[:2] == ["debug-files", "upload"] for call in self.calls))

    def test_existing_server_message_does_not_hide_auth_or_processing_failure(self):
        for stderr in ("authentication failed", "some symbols did not process correctly",
                       "Some symbols could not be found!"):
            with self.subTest(stderr=stderr):
                original_cli = self.cli
                result, evidence, process = self.run_existing_server_response(1, stderr)
                self.cli = original_cli
                self.assertEqual(result, 1)
                self.assertEqual(evidence["status"], "failed")
                self.assertIn("exit 1", evidence["error"])
                process.assert_called_once()

    def test_zero_exit_without_server_completion_still_fails(self):
        for stdout in ("", "> No debug information files found\n", "> skipping upload.\n",
                       "> Found 4 debug information files\n", "> Uploaded 4 missing debug information files\n",
                       "> File upload complete:\n"):
            with self.subTest(stdout=stdout):
                original_cli = self.cli
                result, evidence, process = self.run_existing_server_response(stdout=stdout)
                self.cli = original_cli
                self.assertEqual(result, 1)
                self.assertEqual(evidence["status"], "failed")
                self.assertIn("did not confirm server", evidence["error"])
                process.assert_called_once()

    def test_same_architecture_wrong_dart_build_id_fails(self):
        dart = self.build / "debug-info/app.windows-x64.symbols"
        dart.write_bytes(elf_fixture(build_id="876543210fedcba9876543210fedcba987654321"))
        result, evidence = self.run_main(token="fixture-token")
        self.assertEqual(result, 1)
        self.assertIn("build identifier mismatch", evidence["error"])

    def test_same_architecture_wrong_dart_debug_id_fails(self):
        dart = self.build / "debug-info/app.windows-x64.symbols"
        self.metadata[str(dart)]["variants"][0]["debug_id"] = OTHER_ID
        result, evidence = self.run_main(token="fixture-token")
        self.assertEqual(result, 1)
        self.assertIn("debug identifier mismatch", evidence["error"])

    def test_complete_aot_elf_renamed_as_symbols_cannot_upload(self):
        dart = self.build / "debug-info/app.windows-x64.symbols"
        dart.write_bytes(elf_fixture(executable=True))
        result, evidence = self.run_main(token="fixture-token")
        self.assertEqual(result, 1)
        self.assertIn("contains executable code", evidence["error"])


class CliMetadataTest(unittest.TestCase):
    def test_pe_without_embedded_debug_is_valid_for_pdb_matching(self):
        metadata = {"type": "pe", "variants": [{"debug_id": DEBUG_ID}],
                    "features": "none", "is_usable": False}
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary).resolve() / "fixture.exe"
            binary.write_bytes(b"fixture")
            response = subprocess.CompletedProcess([], 1, stdout=json.dumps(metadata), stderr="")
            with mock.patch.object(symbols.subprocess, "run", return_value=response):
                info = symbols.check_symbol("sentry-cli", binary, "pe")
            self.assertEqual(info["debug_ids"], [DEBUG_ID])

    def test_unusable_pdb_cannot_be_uploaded(self):
        metadata = {"type": "pdb", "variants": [{"debug_id": DEBUG_ID}],
                    "features": "none", "is_usable": False}
        with tempfile.TemporaryDirectory() as temporary:
            pdb = Path(temporary).resolve() / "fixture.pdb"
            pdb.write_bytes(b"fixture")
            response = subprocess.CompletedProcess([], 1, stdout=json.dumps(metadata), stderr="")
            with mock.patch.object(symbols.subprocess, "run", return_value=response), \
                 self.assertRaises(symbols.SymbolError):
                symbols.check_symbol("sentry-cli", pdb, "pdb")

    def test_cli_failure_does_not_echo_raw_stderr_or_credentials(self):
        response = subprocess.CompletedProcess([], 1, stdout="", stderr="DSN secret-token C:/sensitive/env.json")
        with mock.patch.object(symbols.subprocess, "run", return_value=response), \
             self.assertRaises(symbols.UploadError) as caught:
            symbols.run_cli("sentry-cli", ["debug-files", "upload", "/safe/stage"])
        self.assertNotIn("secret-token", str(caught.exception))
        self.assertNotIn("env.json", str(caught.exception))


@unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("gcc") and shutil.which("objcopy"),
                     "Real ELF fixture needs Linux gcc and objcopy")
class NativeElfSymbolsTest(unittest.TestCase):
    """Exercise actual ELF files, strip operations and companion identifiers."""

    def setUp(self):
        # Upload protocol/GET behavior is covered by the real confirmation suite;
        # these tests isolate local symbol inventory and staging.
        self.confirm = mock.patch.object(symbols, "confirm_symbol_inventory", return_value=None)
        self.confirmation = self.confirm.start()
        self.addCleanup(self.confirm.stop)
        self.temporary = tempfile.TemporaryDirectory(prefix="xflclash-native-elf-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
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
        self.dart_aot = self.rust_binary.parent / "libapp.so"
        shutil.copyfile(self.binary, self.dart_aot)
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
            return "> File processing complete:\n"
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

    def test_symlink_build_root_alias_keeps_real_native_and_dart_matching(self):
        alias = self.root / "build-alias"
        alias.symlink_to(self.build, target_is_directory=True)
        dart = self.build / f"debug-info/app.linux-{self.architecture}.symbols"
        dart.parent.mkdir()
        shutil.copyfile(self.debug, dart)
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli):
            artifacts, native, _ = symbols.audit_elf_native("sentry-cli", alias, "linux")
            companions, companion_evidence = symbols.collect_companions("sentry-cli", alias, "linux")
        self.assertEqual(artifacts, [self.debug, self.rust_debug])
        self.assertEqual(companions, [dart])
        self.assertEqual(native[0]["build_id"], symbols.inspect_elf(self.binary)["build_id"])
        self.assertEqual(companion_evidence[0]["binaries"][0], symbols.fingerprint(self.dart_aot))

    def test_symlink_root_alias_still_rejects_dart_companion_escape(self):
        alias = self.root / "build-alias"
        alias.symlink_to(self.build, target_is_directory=True)
        outside = self.root / "outside.symbols"
        shutil.copyfile(self.debug, outside)
        dart = self.build / f"debug-info/app.linux-{self.architecture}.symbols"
        dart.parent.mkdir()
        dart.symlink_to(outside)
        with self.assertRaisesRegex(symbols.SymbolError, "escaped its build root"):
            symbols.collect_companions("sentry-cli", alias, "linux")

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
        for target in ("libclash.so", "librust_api.so"):
            binary = prepare.output / "runtime/0" / abi / target
            binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.binary, binary)
            prepare.add(target, abi, binary, [source], "fixture", True)
        shutil.copyfile(self.binary, binary.parent / "libflutter.so")
        manifest_path = prepare.finish()
        manifest = json.loads(manifest_path.read_text())
        manifest["artifacts"] = [entry for entry in manifest["artifacts"] if entry["target"] != "librust_api.so"]
        manifest["required"] = [entry for entry in manifest["required"] if entry["target"] != "librust_api.so"]
        manifest_path.write_text(json.dumps(manifest))
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
             self.assertRaisesRegex(symbols.SymbolError, "mandatory owned module"):
            symbols.audit_elf_native("sentry-cli", self.build, "android")

    def test_android_current_go_and_rust_inventory_does_not_require_removed_jni_bridge(self):
        from prepare_sentry_native_symbols import Preparer
        source = self.root / "unstripped.so"
        shutil.copyfile(self.original, source)
        abi = "arm64-v8a" if self.architecture == "arm64" else "x86_64"
        prepare = Preparer(self.build, "android", "objcopy")
        for target in ("librust_api.so", "libclash.so"):
            binary = prepare.output / "runtime/0" / abi / target
            binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.binary, binary)
            prepare.add(target, abi, binary, [source], "fixture", True)
        shutil.copyfile(self.binary, binary.parent / "libflutter.so")
        prepare.finish()
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli):
            artifacts, evidence, _ = symbols.audit_elf_native("sentry-cli", self.build, "android")
        self.assertEqual(len(artifacts), 2)
        self.assertEqual({entry["target"] for entry in evidence}, {"librust_api.so", "libclash.so"})

    def android_sentry_inventory(self):
        from prepare_sentry_native_symbols import Preparer
        source = self.root / "unstripped.so"
        shutil.copyfile(self.original, source)
        abi = "arm64-v8a" if self.architecture == "arm64" else "x86_64"
        prepare = Preparer(self.build, "android", "objcopy")
        for target in ("librust_api.so", "libclash.so", "libsentry.so", "libsentry-android.so"):
            binary = prepare.output / "runtime/0" / abi / target
            binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.binary, binary)
            prepare.add(target, abi, binary, [source],
                        "sentry_prefab" if target.startswith("libsentry") else "fixture", True)
        shutil.copyfile(self.binary, binary.parent / "libflutter.so")
        return prepare.finish(), binary.parent

    def test_android_actual_sentry_prefab_companions_pass_debug_only_audit(self):
        self.android_sentry_inventory()
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli):
            artifacts, evidence, limitations = symbols.audit_elf_native("sentry-cli", self.build, "android")
        self.assertEqual(len(artifacts), 4)
        self.assertEqual({entry["target"] for entry in evidence},
                         {"librust_api.so", "libclash.so", "libsentry.so", "libsentry-android.so"})
        self.assertTrue(all(path.suffix == ".debug" and not symbols.inspect_elf(path)["has_executable_text"]
                            for path in artifacts))
        self.assertFalse(limitations)

    def test_android_upload_stages_sentry_prefab_debug_files_with_other_companions(self):
        _, runtime = self.android_sentry_inventory()
        shutil.copyfile(self.binary, runtime / "libapp.so")
        dart = self.build / f"debug-info/app.android-{self.architecture}.symbols"
        dart.parent.mkdir()
        shutil.copyfile(self.debug, dart)
        evidence_file = self.build / "android-evidence.json"

        def cli(executable, arguments):
            if arguments[:2] != ["debug-files", "upload"]:
                return self.cli(executable, arguments)
            staged = [path for path in Path(arguments[-1]).rglob("*") if path.is_file()]
            self.assertEqual({path.name for path in staged},
                             {"librust_api.so.debug", "libclash.so.debug", "libsentry.so.debug",
                              "libsentry-android.so.debug", dart.name})
            self.assertTrue(all(not symbols.inspect_elf(path)["has_executable_text"] for path in staged))
            self.assertIn("--no-sources", arguments)
            self.assertIn("--no-zips", arguments)
            self.assertIn("--wait-for", arguments)
            return "> File processing complete:\n"

        with mock.patch.object(symbols, "run_cli", side_effect=cli), \
             mock.patch.object(symbols.shutil, "which", return_value="fake-cli"), \
             mock.patch.dict(os.environ, {"SENTRY_AUTH_TOKEN": "fixture-secret"}):
            result = symbols.main(["--platform", "android", "--flavor", "brand_a",
                                   "--build-root", str(self.build), "--evidence", str(evidence_file)])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(evidence_file.read_text())["status"], "uploaded_and_processed")
        self.assertNotIn("fixture-secret", evidence_file.read_text())

    def test_android_sentry_cannot_disappear_from_both_manifest_lists(self):
        path, _ = self.android_sentry_inventory()
        original = json.loads(path.read_text())
        for omitted in ({"libsentry.so"}, {"libsentry-android.so"}, {"libsentry.so", "libsentry-android.so"}):
            manifest = json.loads(json.dumps(original))
            for key in ("artifacts", "required"):
                manifest[key] = [entry for entry in manifest[key] if entry["target"] not in omitted]
            path.write_text(json.dumps(manifest))
            with self.subTest(omitted=omitted), mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
                 self.assertRaisesRegex(symbols.SymbolError, "mandatory owned module"):
                symbols.audit_elf_native("sentry-cli", self.build, "android")

    def test_android_required_sentry_cannot_also_be_reported_as_missing(self):
        path, runtime = self.android_sentry_inventory()
        manifest = json.loads(path.read_text())
        manifest["limitations"].append({"target": "libsentry.so", "architecture": runtime.name,
                                       "source": "gradle", "reason": "prebuilt_debug_companion_unavailable"})
        path.write_text(json.dumps(manifest))
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
             self.assertRaisesRegex(symbols.SymbolError, "cannot also be a limitation"):
            symbols.audit_elf_native("sentry-cli", self.build, "android")

    def test_android_sentry_modules_must_agree_between_final_apks(self):
        _, runtime = self.android_sentry_inventory()
        other = runtime.parent.parent / "1" / runtime.name
        shutil.copytree(runtime, other)
        shutil.copyfile(self.original, other / "libsentry.so")
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
             self.assertRaisesRegex(symbols.SymbolError, "conflicting owned native modules"):
            symbols.audit_elf_native("sentry-cli", self.build, "android")

    def test_android_actually_distributed_rust_cannot_be_omitted_from_manifest(self):
        from prepare_sentry_native_symbols import Preparer
        source = self.root / "unstripped.so"
        shutil.copyfile(self.original, source)
        abi = "arm64-v8a" if self.architecture == "arm64" else "x86_64"
        prepare = Preparer(self.build, "android", "objcopy")
        for target in ("libclash.so", "librust_api.so"):
            binary = prepare.output / "runtime/0" / abi / target
            binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.binary, binary)
            prepare.add(target, abi, binary, [source], "fixture", True)
        shutil.copyfile(self.binary, binary.parent / "libflutter.so")
        manifest_path = prepare.finish()
        manifest = json.loads(manifest_path.read_text())
        for key in ("artifacts", "required"):
            manifest[key] = [entry for entry in manifest[key] if entry["target"] != "librust_api.so"]
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
        for target in ("libclash.so", "librust_api.so"):
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
        for target in ("libclash.so", "librust_api.so", "libflutter.so"):
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

    def linux_handler_inventory(self):
        native = self.binary.parent.parent
        source = native / "_deps/sentry-native-build/handler/crashpad_handler"
        source.parent.mkdir(parents=True)
        shutil.copyfile(self.original, source)
        runtime = self.binary.parent / "lib/crashpad_handler"
        shutil.copyfile(self.binary, runtime)
        copy = self.binary.parent / "bin/crashpad_handler"
        copy.parent.mkdir()
        shutil.copyfile(self.original, copy)
        debug = self.native / "crashpad_handler.debug"
        shutil.copyfile(self.debug, debug)
        self.cmake_map.write_text(self.cmake_map.read_text() + f"handler_target\t{source}\n")
        entry = {"target": "crashpad_handler", "architecture": self.architecture, "source": "cmake",
                 "binary": runtime.relative_to(self.build).as_posix(),
                 "binary_copies": [path.relative_to(self.build).as_posix() for path in (runtime, copy)],
                 "debug_file": debug.relative_to(self.build).as_posix()}
        self.manifest["artifacts"].append(entry)
        self.manifest["required"].append({"target": "crashpad_handler", "architecture": self.architecture})
        self.write_manifest()
        return entry, runtime, copy

    def test_linux_handler_audits_every_runtime_copy_and_records_fingerprints(self):
        _, runtime, copy = self.linux_handler_inventory()
        _, evidence, _ = self.audit()
        handler = next(entry for entry in evidence if entry["target"] == "crashpad_handler")
        self.assertEqual(len(handler["binary_copies"]), 2)
        self.assertEqual({item["sha256"] for item in handler["binary_copies"]},
                         {symbols.fingerprint(path)["sha256"] for path in (runtime, copy)})

    def test_linux_handler_cannot_be_removed_from_both_manifest_lists(self):
        self.linux_handler_inventory()
        for field in ("artifacts", "required"):
            self.manifest[field] = [entry for entry in self.manifest[field] if entry["target"] != "crashpad_handler"]
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "distributed CMake"):
            self.audit()

    def test_linux_handler_cannot_disappear_by_also_truncating_the_cmake_map(self):
        self.linux_handler_inventory()
        self.cmake_map.write_text(self.cmake_map.read_text().split("handler_target\t", 1)[0])
        for field in ("artifacts", "required"):
            self.manifest[field] = [entry for entry in self.manifest[field] if entry["target"] != "crashpad_handler"]
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "crashpad_source_manifest_missing"):
            self.audit()

    def test_linux_handler_upload_record_cannot_omit_one_installed_copy(self):
        entry, *_ = self.linux_handler_inventory()
        entry["binary_copies"].pop()
        self.write_manifest()
        with self.assertRaisesRegex(symbols.SymbolError, "runtime copy"):
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
        shutil.copyfile(self.debug, dart)
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


class LocalUploadEntrypointTest(unittest.TestCase):
    def test_config_logging_never_prints_private_values(self):
        sys.path.insert(0, str(SCRIPT.parents[1]))
        from tool.test.release_pipeline_test import context
        for relative in (".github/workflows/release-package.yml", "scripts/package_desktop_local.sh"):
            text = (SCRIPT.parents[1] / relative).read_text(encoding="utf-8")
            self.assertIn("tool/release_pipeline.py compose", text)
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                (root / "build").mkdir()
                (root / "build/release-context.json").write_text(json.dumps(context()))
                (root / "flavor_defines.json").write_text(json.dumps({"XB_FLAVOR_ID":"brand_a",
                    "XB_AES_KEY_B64":"fixture-private-aes", "XB_SENTRY_DSN":"fixture-private-dsn",
                    "NEW_PRIVATE_DEFINE":"fixture-other-private"}))
                result = subprocess.run([sys.executable, str(SCRIPT.parent / "release_pipeline.py"), "compose"],
                                        cwd=root, capture_output=True, text=True, check=True, timeout=10)
                self.assertNotIn("fixture-private", result.stdout + result.stderr)
                self.assertNotIn("fixture-other-private", result.stdout + result.stderr)
                self.assertEqual(json.loads((root / "env.json").read_text())["NEW_PRIVATE_DEFINE"], "fixture-other-private")


def write_windows_symbol_fixture(source):
    """Use the production root language setup and a child C-only DLL target."""
    source.mkdir()
    windows = SCRIPT.parents[1] / "windows"
    project = next(line for line in (windows / "CMakeLists.txt").read_text().splitlines()
                   if line.startswith("project("))
    (source / "CMakeLists.txt").write_text('''cmake_minimum_required(VERSION 3.14)
''' + project + '''
file(WRITE "${CMAKE_BINARY_DIR}/root-c-compiler.txt" "${CMAKE_C_COMPILER_LOADED}")
add_library(wrapper STATIC wrapper.cpp)
add_executable(FlClash main.cpp)
target_link_libraries(FlClash PRIVATE wrapper)
add_library(flutter_inappwebview_windows_plugin SHARED plugin.cpp)
add_library(desktop_webview_window_plugin SHARED plugin.cpp)
add_subdirectory(sqlite)
include("''' + (windows / "xboard_sentry_symbols.cmake").as_posix() + '''")
''')
    (source / "wrapper.cpp").write_text("int fixture_wrapper() { return 7; }\n")
    (source / "main.cpp").write_text("int fixture_wrapper(); int main() { return fixture_wrapper(); }\n")
    export = '__declspec(dllexport) ' if os.name == "nt" else ''
    (source / "plugin.cpp").write_text(export + "int fixture_plugin() { return 9; }\n")
    child = source / "sqlite"
    child.mkdir()
    (child / "CMakeLists.txt").write_text('''project(sqlite_fixture LANGUAGES C)
add_library(sqlite3 SHARED sqlite3.c)
set_target_properties(sqlite3 PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/$<CONFIG>")
''')
    (child / "sqlite3.c").write_text(export + "int fixture_sqlite(void) { return 42; }\n")


@unittest.skipUnless(shutil.which("cmake") and (os.name == "nt" or shutil.which("c++")),
                     "Native C/C++ CMake fixture tools unavailable")
class WindowsRootLanguagesTest(unittest.TestCase):
    def test_production_root_initializes_c_before_child_c_only_library(self):
        try:
            from .windows_loader_install_test import find_cmake
        except ImportError:
            from windows_loader_install_test import find_cmake
        with tempfile.TemporaryDirectory(prefix="xflclash-root-c-") as temporary:
            root = Path(temporary).resolve()
            source, build = root / "source", root / "build"
            write_windows_symbol_fixture(source)
            for args in (["-S", str(source), "-B", str(build)],
                         ["--build", str(build), "--config", "Release"]):
                subprocess.run([find_cmake(), *args], check=True, capture_output=True, timeout=180)
            # Captured before the child enables C: a child-only compiler setup
            # cannot initialize the parent's PDB generator-expression context.
            self.assertEqual((build / "root-c-compiler.txt").read_text(), "1")


@unittest.skipUnless(os.name == "nt", "Actual MSVC/PDB generation requires Windows")
class NativeWindowsSymbolsTest(unittest.TestCase):
    def test_production_rules_generate_matching_pdb_for_runner_and_plugins(self):
        # Native CI test, not a string assertion about compiler/linker flags.
        try:
            from .windows_loader_install_test import find_cmake
        except ImportError:
            from windows_loader_install_test import find_cmake
        cli = shutil.which("sentry-cli")
        self.assertIsNotNone(cli, "CI must install sentry-cli before this test")
        with tempfile.TemporaryDirectory(prefix="xflclash-msvc-symbols-") as temporary:
            root = Path(temporary).resolve()
            source, build = root / "source with spaces", root / "build with spaces"
            write_windows_symbol_fixture(source)
            for args in (["-S", str(source), "-B", str(build)],
                         ["--build", str(build), "--config", "Release"]):
                subprocess.run([find_cmake(), *args], check=True, capture_output=True, timeout=180)
            files, evidence = symbols.audit_windows(cli, build)
            self.assertEqual(len(files), 4)
            self.assertEqual({item["target"] for item in evidence},
                             {"FlClash", "flutter_inappwebview_windows_plugin", "desktop_webview_window_plugin", "sqlite3"})
            self.assertTrue(all("debug" in item["features"] for item in evidence))
            self.assertTrue(all(path.parent.resolve() == (build / "sentry-symbols/Release").resolve() for path in files))
            self.assertFalse(any(path.parent.resolve() == (build / "Release").resolve() for path in files))


if __name__ == "__main__":
    unittest.main(verbosity=2)
