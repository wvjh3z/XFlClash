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
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "upload_sentry_symbols.py"
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
        result, evidence = self.run_main(platform="android")
        self.assertEqual(result, 0)
        self.assertEqual(evidence["status"], "skipped_missing_token")
        self.assertEqual(evidence["native_coverage"], "pending_separate_debug_companions")

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
