#!/usr/bin/env python3
"""Offline boundaries for the temporary manifest/Xcode diagnostic harness."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagnose_macos_inventory_manifests as diagnostic
import pick_sentry_symbolication_probe as picker
import sentry_macos_generation_test as generation


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="manifest-diag-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "client project with 'quotes'"
        (self.project / "macos/Runner.xcodeproj").mkdir(parents=True)
        (self.project / "macos/Runner.xcodeproj/project.pbxproj").write_text("fixture")

    def test_script_project_contains_no_sources_packages_or_client_link(self):
        directory = self.root / "probe"
        directory.mkdir()
        reports = {mode: self.root / (mode + ".json") for mode in diagnostic.MODES}
        bundle = diagnostic.write_xcode_project(directory, self.project, reports)
        text = (bundle / "project.pbxproj").read_text()
        self.assertIn("PBXAggregateTarget", text)
        self.assertNotIn("PBXSourcesBuildPhase", text)
        self.assertNotIn("packageReferences", text)
        self.assertNotIn("PBXFrameworksBuildPhase", text)
        self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING = NO", text)
        self.assertIn("showEnvVarsInLog = 0", text)
        self.assertEqual(text.count("--worker"), 2)
        self.assertIn("--mode xcode_original", text)
        self.assertIn("--mode xcode_host", text)
        # Exact command quoting survives both the PBX string and shell layers.
        start = text.index("shellScript = ") + len("shellScript = ")
        script, _ = json.JSONDecoder().raw_decode(text[start:])
        import shlex
        lines = script.splitlines()[1:]
        self.assertEqual(len(lines), 2)
        self.assertEqual(shlex.split(lines[0])[-3], str(self.project))

    def test_worker_reuses_shared_graph_and_projects_environment_presence_only(self):
        report = self.root / "worker.json"
        environment = {"SDKROOT": "/private/fake-sdk", "SWIFT_EXEC": "/private/swiftc",
                       "FAKE_TOKEN": "fake-private-token"}
        response = {"status": "failed", "closure_complete": False, "manifests": []}
        with mock.patch.dict(os.environ, environment, clear=True), \
             mock.patch.object(diagnostic.inventory, "diagnose_manifests", create=True,
                               return_value=response) as helper:
            self.assertEqual(diagnostic.worker(self.project, "xcode_host", report), 0)
        self.assertEqual(helper.call_args.kwargs["environment_mode"], "host")
        self.assertIsNone(helper.call_args.kwargs["swift"])
        self.assertEqual(helper.call_args.args, (self.project, self.project / "build"))
        value = json.loads(report.read_text())
        self.assertEqual(value["mode"], "xcode_host")
        self.assertTrue(value["environment_present"]["SDKROOT"])
        self.assertNotIn("fake-private-token", report.read_text())
        self.assertNotIn("/private/", report.read_text())

    def test_failed_original_still_collects_host_and_smoke(self):
        report = self.root / "final.json"
        def xcode(arguments, **kwargs):
            if "--worker" in arguments:
                diagnostic.write_json(Path(arguments[-1]), {"mode": "shell", "status": "complete"})
                return {"status": "complete"}
            self.assertEqual(arguments[:2], ["xcrun", "xcodebuild"])
            self.assertNotIn("-resolvePackageDependencies", arguments)
            self.assertNotEqual(Path(arguments[arguments.index("-project") + 1]),
                                self.project / "macos/Runner.xcodeproj")
            directory = Path(kwargs["cwd"])
            diagnostic.write_json(directory / "xcode_original.json", {"mode": "xcode_original", "status": "failed"})
            diagnostic.write_json(directory / "xcode_host.json", {"mode": "xcode_host", "status": "complete"})
            return {"status": "complete"}

        with mock.patch.object(diagnostic, "run_quiet", side_effect=xcode), \
             mock.patch.object(diagnostic, "macho_smoke", return_value={"status": "complete"}) as smoke, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(diagnostic.diagnose(self.project, report), 1)
        value = json.loads(report.read_text())
        self.assertEqual([item["mode"] for item in value["modes"]], list(diagnostic.MODES))
        self.assertFalse(value["client_build_performed"])
        self.assertFalse(value["package_resolution_performed"])
        self.assertFalse(value["rootcause_proven"])
        self.assertFalse(value["runner_environment_equivalence_proven"])
        smoke.assert_called_once()

    def test_xcode_failure_still_preserves_shell_and_records_missing_modes(self):
        report = self.root / "final.json"
        def command(arguments, **kwargs):
            if "--worker" in arguments:
                diagnostic.write_json(Path(arguments[-1]), {"mode": "shell", "status": "complete"})
                return {"status": "complete"}
            return {"status": "failed", "reason": "command_timeout"}
        with mock.patch.object(diagnostic, "run_quiet", side_effect=command), \
             mock.patch.object(diagnostic, "macho_smoke", return_value={"status": "complete"}), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(diagnostic.diagnose(self.project, report), 1)
        value = json.loads(report.read_text())
        self.assertEqual(value["modes"][0]["status"], "complete")
        self.assertEqual(value["modes"][1]["reason"], "mode_report_unavailable")

    def test_inherited_modes_keep_original_tool_selection(self):
        with mock.patch.object(diagnostic.shutil, "which", return_value="/private/original-swift"), \
             mock.patch.object(diagnostic.inventory, "diagnose_manifests", return_value={"status": "complete"}) as helper:
            diagnostic.worker(self.project, "xcode_original", self.root / "inherited.json")
        self.assertEqual(helper.call_args.kwargs["swift"], "/private/original-swift")
        self.assertEqual(helper.call_args.kwargs["environment_mode"], "inherited")
        self.assertNotIn("/private/", (self.root / "inherited.json").read_text())

    def test_native_smoke_calls_real_picker_on_exact_fixture_companion(self):
        (self.root / "ManifestProbe.o").write_bytes(b"retained object")
        with mock.patch.object(diagnostic.platform, "machine", return_value="arm64"), \
             mock.patch.object(diagnostic, "run_quiet", return_value={"status": "complete"}) as command, \
             mock.patch.object(diagnostic, "macho_debug_preflight", return_value={"status": "complete"}), \
             mock.patch.object(diagnostic, "pick_macho", return_value=(0x1234, {"filename": "ManifestProbe.c", "lineno": 2})) as picker, \
             mock.patch.object(diagnostic, "diagnose_macho_line_rows", return_value={"status": "complete"}) as rows:
            result = diagnostic.macho_smoke(self.root, {})
        self.assertEqual(result["status"], "complete")
        self.assertTrue(result["native_nm_atos_parsed"])
        self.assertEqual(command.call_args_list[0].args[0][:2], ["xcrun", "clang"])
        self.assertIn("-c", command.call_args_list[0].args[0])
        self.assertEqual(command.call_args_list[0].args[0][-1], str(self.root / "ManifestProbe.o"))
        self.assertIn(str(self.root / "ManifestProbe.o"), command.call_args_list[1].args[0])
        self.assertIn("-g", command.call_args_list[1].args[0])
        self.assertEqual(command.call_args_list[2].args[0][:2], ["xcrun", "dsymutil"])
        self.assertEqual(picker.call_args.args, (self.root / "ManifestProbe",
                         self.root / "ManifestProbe.dSYM/Contents/Resources/DWARF/ManifestProbe", "arm64"))
        self.assertEqual(picker.call_args.kwargs["candidate_limit"], 12)
        self.assertEqual(picker.call_args.kwargs["lookup_timeout"], 10)
        self.assertEqual(rows.call_args.kwargs["candidate_limit"], 12)

    def test_failed_native_smoke_keeps_safe_stage_and_remaining_real_line_pc_budget(self):
        (self.root / "ManifestProbe.o").write_bytes(b"retained object")
        def failed(*args, **kwargs):
            kwargs["diagnostics"].update(stage="source_line_unavailable", attempts=3,
                                        atos_output_shapes={"symbol_offset_only": 3})
            raise diagnostic.ProbeError("no_native_instruction_with_source_line")
        with mock.patch.object(diagnostic.platform, "machine", return_value="arm64"), \
             mock.patch.object(diagnostic, "run_quiet", return_value={"status": "complete"}), \
             mock.patch.object(diagnostic, "macho_debug_preflight", return_value={"status": "complete"}), \
             mock.patch.object(diagnostic, "pick_macho", side_effect=failed), \
             mock.patch.object(diagnostic, "diagnose_macho_line_rows", return_value={"status": "complete"}) as rows:
            result = diagnostic.macho_smoke(self.root, {})
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["lookup"]["atos_output_shapes"], {"symbol_offset_only": 3})
        self.assertEqual(result["stages"]["compile"]["status"], "complete")
        self.assertEqual(rows.call_args.kwargs["candidate_limit"], 9)
        self.assertNotIn("no_native_instruction", json.dumps(result))

    def test_empty_dsym_or_absent_object_cannot_reach_atos(self):
        with mock.patch.object(diagnostic.platform, "machine", return_value="arm64"), \
             mock.patch.object(diagnostic, "run_quiet", return_value={"status": "complete"}), \
             mock.patch.object(diagnostic, "pick_macho") as picker:
            result = diagnostic.macho_smoke(self.root, {})
        self.assertEqual(result["reason"], "macho_fixture_object_unavailable")
        picker.assert_not_called()
        (self.root / "ManifestProbe.o").write_bytes(b"retained object")
        with mock.patch.object(diagnostic.platform, "machine", return_value="arm64"), \
             mock.patch.object(diagnostic, "run_quiet", return_value={"status": "complete"}), \
             mock.patch.object(diagnostic, "macho_debug_preflight", return_value={"status": "failed", "positive_rows": 0}), \
             mock.patch.object(diagnostic, "pick_macho") as picker:
            result = diagnostic.macho_smoke(self.root, {})
        self.assertEqual(result["reason"], "macho_fixture_debug_information_unavailable")
        picker.assert_not_called()

    def test_debug_preflight_requires_uuid_dwarf_and_real_positive_line_rows(self):
        runtime = dict(architecture="arm64", uuid="fixture-uuid")
        debug = dict(architecture="arm64", uuid="fixture-uuid", has_debug_info=True,
                     has_debug_line=True, filetype=10, has_executable_text=False)
        for mutated, rows, complete in (({}, 2, True), ({"has_debug_info": False}, 2, False),
                ({"has_debug_line": False}, 2, False), ({"uuid": "other"}, 2, False),
                ({"has_executable_text": True}, 2, False), ({}, 0, False)):
            with self.subTest(mutated=mutated, rows=rows), \
                 mock.patch.object(diagnostic, "inspect_macho", side_effect=[{"variants": [runtime]}, {"variants": [{**debug, **mutated}]}]), \
                 mock.patch.object(diagnostic, "diagnose_macho_line_rows", return_value={"status": "complete", "in_range_row_count": rows}) as lookup:
                result = diagnostic.macho_debug_preflight(Path("runtime"), Path("dwarf"), "arm64")
            self.assertEqual(result["status"] == "complete", complete)
            if lookup.called:
                self.assertEqual(lookup.call_args.kwargs["candidate_limit"], 0)

    def test_native_only_scope_never_claims_manifest_or_resolves_graph(self):
        report = self.root / "native-only.json"
        with mock.patch.object(diagnostic.sys, "platform", "darwin"), \
             mock.patch.object(diagnostic, "macho_smoke", return_value={"status": "complete"}), \
             mock.patch.object(diagnostic.inventory, "diagnose_manifests") as manifests, \
             mock.patch.object(diagnostic, "write_xcode_project") as xcode, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(diagnostic.main(["--native-lookup-only", "--project-root", str(self.root), "--report", str(report)]), 0)
        value = json.loads(report.read_text())
        self.assertEqual(value["scope"], "native_lookup_only")
        self.assertFalse(value["manifest_validation_performed"])
        self.assertFalse(value["package_resolution_performed"])
        self.assertNotIn("modes", value)
        self.assertNotIn("closure_complete", value)
        manifests.assert_not_called()
        xcode.assert_not_called()

    @unittest.skipUnless(os.name == "posix" and generation.CLANG and generation.LINKER and generation.DSYMUTIL,
                         "Real Mach-O fixture tools unavailable")
    def test_real_retained_object_has_lines_and_missing_oso_is_rejected(self):
        nm = generation.tool_path("llvm-nm") or generation.shutil.which("nm")
        dwarfdump = generation.tool_path("llvm-dwarfdump") or generation.shutil.which("dwarfdump")
        if not nm or not dwarfdump:
            self.skipTest("Native nm/dwarfdump unavailable")
        source, obj, binary = (self.root / name for name in ("Fixture.c", "Fixture.o", "Fixture"))
        good, bad = self.root / "good.dSYM", self.root / "bad.dSYM"
        source.write_text("int main(void) { return 7; }\n")
        for command in ([generation.CLANG, "--target=x86_64-apple-macos11", "-g", "-O0", "-c", str(source), "-o", str(obj)],
                        generation.fixture_link_command(binary, [obj]),
                        [generation.DSYMUTIL, str(binary), "-o", str(good)]):
            self.assertEqual(subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, 0)
        tools = {"nm": nm, "dwarfdump": dwarfdump, "atos": "not-executed-before-positive-row-gate"}
        with mock.patch.object(picker, "find_tool", side_effect=lambda name, **kwargs: tools[name]):
            result = diagnostic.macho_debug_preflight(binary, good / "Contents/Resources/DWARF/Fixture", "x86_64")
        self.assertEqual(result["status"], "complete")
        self.assertGreater(result["positive_rows"], 0)
        self.assertTrue(result["uuid_matches"])
        obj.unlink()
        # A linker debug map whose object has vanished can still produce an
        # empty dSYM with exit zero. That must never reach the atos picker.
        subprocess.run([generation.DSYMUTIL, str(binary), "-o", str(bad)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result = diagnostic.macho_debug_preflight(binary, bad / "Contents/Resources/DWARF/Fixture", "x86_64")
        self.assertEqual(result["status"], "failed")

    def test_unsupported_host_and_private_exception_are_fixed(self):
        with mock.patch.object(diagnostic.platform, "machine", return_value="private-platform"):
            self.assertEqual(diagnostic.macho_smoke(self.root, {})["reason"], "unsupported_host_architecture")
        report = self.root / "exception.json"
        output = io.StringIO()
        with mock.patch.object(diagnostic.sys, "platform", "darwin"), \
             mock.patch.object(diagnostic, "diagnose", side_effect=RuntimeError("fake-private-token /private/source")), \
             contextlib.redirect_stderr(output):
            self.assertEqual(diagnostic.main(["--project-root", str(self.project), "--report", str(report)]), 1)
        self.assertNotIn("fake-private-token", output.getvalue() + report.read_text())
        self.assertNotIn("/private/source", output.getvalue() + report.read_text())

    @unittest.skipUnless(os.name == "posix", "POSIX subprocess boundary")
    def test_real_failing_command_does_not_capture_private_output(self):
        capture = io.StringIO()
        with contextlib.redirect_stdout(capture), contextlib.redirect_stderr(capture):
            result = diagnostic.run_quiet([sys.executable, "-c", "import sys; print('fake-private-token'); print('/private/source', file=sys.stderr); sys.exit(7)"])
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(capture.getvalue(), "")
        self.assertNotIn("private", json.dumps(result))

    def test_report_write_failure_cannot_relay_original_exception(self):
        output = io.StringIO()
        with mock.patch.object(diagnostic.sys, "platform", "darwin"), \
             mock.patch.object(diagnostic, "diagnose", side_effect=RuntimeError("fake-private-token")), \
             mock.patch.object(diagnostic, "write_json", side_effect=OSError("/private/report")), \
             contextlib.redirect_stderr(output):
            self.assertEqual(diagnostic.main(["--project-root", str(self.project)]), 1)
        self.assertEqual(output.getvalue(), "inventory_manifest_diagnostic: diagnostic_execution_failed\n")

    @unittest.skipUnless(os.name == "posix", "POSIX process group cleanup")
    def test_real_timeout_is_bounded_and_private(self):
        started = time.monotonic()
        result = diagnostic.run_quiet([sys.executable, "-c", "import time; time.sleep(60)"], timeout=0.05)
        self.assertEqual(result["reason"], "command_timeout")
        self.assertLess(time.monotonic() - started, 3)


if __name__ == "__main__":
    unittest.main()
