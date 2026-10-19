#!/usr/bin/env python3
"""No-compiler Rust reader lifecycle, diagnostic and per-slice regressions."""

import contextlib
import io
import inspect
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
sys.path.insert(0, str(TOOL / "test"))
import prepare_sentry_macos_symbols as preparation
import owned_process_cleanup as cleanup
from ready_debug_reader import ReadyReader, OffsetClock, STARTUP_TIMEOUT
from sentry_macos_inventory import write_inventory
from sentry_macos_symbols_test import macho, universal


@unittest.skipUnless(os.name == "posix", "Reader executable/pipe fixtures require POSIX")
class RustReaderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sentry-reader-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.retained_diagnostics = os.environ.get("SENTRY_MACOS_DIAGNOSTICS_DIR")
        # Expected negative fixtures must not replace another CI test's evidence.
        patcher = mock.patch.dict(os.environ, {"SENTRY_MACOS_DIAGNOSTICS_DIR": str(self.root / "diagnostics")})
        patcher.start()
        self.addCleanup(patcher.stop)

    def tool(self, source):
        path = self.root / "dwarfdump"
        path.write_text("#!" + sys.executable + "\n" + source)
        path.chmod(0o755)
        return str(path)

    def scan(self, source, *, timeout=2, diagnostic=None):
        return preparation.contains_rust_debug(self.tool(source), self.root / "private-input",
                                              architecture="x86_64", timeout=timeout, diagnostic=diagnostic)

    def test_short_output_immediate_exit_is_stable_with_and_without_newline(self):
        for _ in range(4):
            for output, expected in (("", False), ("DW_AT_language (DW_LANG_C11)\n", False),
                                     ("DW_AT_language (DW_LANG_Rust)\n", True),
                                     ("DW_AT_language (DW_LANG_Rust)", True)):
                with self.subTest(output=output):
                    diagnostic = {}
                    self.assertEqual(self.scan("import sys\nsys.stdout.write(" + repr(output) + ")\n",
                                               diagnostic=diagnostic), expected)
                    self.assertTrue(diagnostic["reaped"])
                    self.assertTrue(diagnostic["pipe_closed"])
                    self.assertEqual(diagnostic["cleanup"], "complete")
                    self.assertEqual(diagnostic["phase"], "complete")

    def retain_ready_failure(self, mode, diagnostic, readiness):
        # Only unexpected test failures escape the isolated negative-fixture
        # directory. Two fixed files survive cleanup via the existing artifact.
        if not self.retained_diagnostics or mode not in {'eof', 'held'}:
            return
        try:
            directory = Path(self.retained_diagnostics)
            if directory.is_symlink():
                return
            directory.mkdir(parents=True, exist_ok=True)
            value = {'schema_version': 1, 'case': mode,
                     'diagnostic': preparation.safe_diagnostic(diagnostic),
                     'readiness': {name: readiness.get(name) is True for name in
                         ('parent_ready', 'child_ready', 'parent_exited', 'termination_witnessed')}}
            fd = os.open(directory / ('reader-test-' + mode + '.json'),
                         os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, 'O_NOFOLLOW', 0), 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                json.dump(value, stream, sort_keys=True)
        except (OSError, ValueError, TypeError):
            pass  # Optional evidence must not mask the failing assertion.

    def ready_timeout(self, mode, *, startup_delay=0):
        diagnostic = {}
        reader = ReadyReader(self.root, mode, startup_delay=startup_delay)
        try:
            self.check_ready_timeout(reader, diagnostic)
        except BaseException:
            self.retain_ready_failure(mode, diagnostic, reader.evidence())
            raise

    def check_ready_timeout(self, reader, diagnostic):
        mode = reader.mode
        clock = OffsetClock()
        self.assertEqual(preparation.RUST_DWARFDUMP_TIMEOUT, 60)
        self.assertEqual(inspect.signature(preparation.contains_rust_debug).parameters['timeout'].default, 60)
        with reader:
            if mode == 'held':
                reader.exit_parent()  # Reaped leader, live descendant owns stdout.
            original_read = preparation.read_debug_pipe
            original_selector = preparation.selectors.DefaultSelector
            observed = []

            def read(descriptor, size):
                chunk = original_read(descriptor, size)
                if not chunk:
                    reader.assert_alive(('parent',))
                    observed.append('eof')
                    clock.advance(61)  # Only after the real EOF reaches the reader.
                return chunk

            case = self
            class Selector:
                def __init__(self):
                    self.inner = original_selector()
                def __enter__(self):
                    self.inner.__enter__()
                    return self
                def __exit__(self, *args):
                    return self.inner.__exit__(*args)
                def __getattr__(self, name):
                    return getattr(self.inner, name)
                def select(self, timeout):
                    events = self.inner.select(0)
                    case.assertEqual(events, [], 'Live descendant must still own stdout')
                    reader.assert_alive(('child',))
                    observed.append('held')
                    clock.advance(61)
                    return events

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(preparation, 'time', clock))
                self.assertIs(cleanup.time, time)  # Never freeze real cleanup deadlines.
                stack.enter_context(mock.patch.object(preparation, 'launch_debug_reader', return_value=reader.process))
                if mode == 'eof':
                    stack.enter_context(mock.patch.object(preparation, 'read_debug_pipe', side_effect=read))
                else:
                    stack.enter_context(mock.patch.object(preparation.selectors, 'DefaultSelector', Selector))
                kill = stack.enter_context(mock.patch.object(preparation.os, 'killpg', wraps=os.killpg))
                wait = stack.enter_context(mock.patch.object(reader.process, 'wait', wraps=reader.process.wait))
                with self.assertRaisesRegex(preparation.PreparationError, '^macos_rust_dwarfdump_timeout$'):
                    preparation.contains_rust_debug('unused-fixture', self.root / 'private-input',
                                                    architecture='x86_64', diagnostic=diagnostic)
            if mode == 'eof':
                self.assertEqual(wait.call_args_list[0].kwargs['timeout'], .001)
            self.assertEqual(observed, ['eof' if mode == 'eof' else 'held'])
            self.assertEqual(clock.offset, 61)
            self.assertEqual(diagnostic['phase'], 'wait' if mode == 'eof' else 'read')
            self.assertEqual(diagnostic['eof'], mode == 'eof')
            self.assertTrue(diagnostic['reaped'])
            self.assertTrue(diagnostic['pipe_closed'])
            self.assertEqual(diagnostic['cleanup'], 'complete')
            self.assertEqual([call.args[1] for call in kill.call_args_list], [signal.SIGTERM, signal.SIGKILL])
            if mode == 'held':
                self.assertEqual(diagnostic['returncode'], 0)
            reader.assert_closed()

    def test_eof_before_exit_waits_with_deadline_and_reaps(self):
        self.ready_timeout('eof')

    def test_slow_startup_cannot_consume_reader_phase_test_budget(self):
        # Deliberately exceed both former 150/200ms assumptions, including the
        # descendant's own startup. No scheduler speed is required for success.
        for mode in ('eof', 'held'):
            with self.subTest(mode=mode):
                self.ready_timeout(mode, startup_delay=.35)

    def test_readiness_deadline_and_missing_readiness_are_not_success(self):
        self.assertEqual(STARTUP_TIMEOUT, 15)
        fixture = ReadyReader(self.root, 'held', startup_timeout=0)
        with self.assertRaisesRegex(AssertionError, 'readiness deadline'):
            with fixture:
                self.fail('Unready fixture entered test')
        self.assertIsNotNone(fixture.process.returncode)
        self.assertTrue(fixture.process.stdout.closed)
        with self.assertRaisesRegex(AssertionError, 'without readiness'):
            fixture.assert_closed()

    def test_live_descendant_is_not_mistaken_for_successful_cleanup(self):
        with ReadyReader(self.root, 'held') as reader:
            reader.exit_parent()
            with self.assertRaisesRegex(AssertionError, 'still alive'):
                reader.assert_closed(timeout=.05)
            cleanup.cleanup_owned_group(reader.process)
            reader.assert_closed()

    def test_only_unexpected_ready_failure_retains_bounded_safe_evidence(self):
        self.retained_diagnostics = str(self.root / 'retained')
        # A normal expected production timeout must not become a failure artifact.
        self.ready_timeout('eof')
        destination = Path(self.retained_diagnostics)
        self.assertFalse(destination.exists())
        original = self.check_ready_timeout
        def failed(reader, diagnostic):
            original(reader, diagnostic)  # Real cleanup completes before assertion failure.
            diagnostic.update(message='private-token', path='/private/path')
            raise AssertionError('private-token /private/path')
        with mock.patch.object(self, 'check_ready_timeout', side_effect=failed):
            with self.assertRaises(AssertionError):
                self.ready_timeout('eof')
        report = destination / 'reader-test-eof.json'
        data = json.loads(report.read_text(encoding='utf-8'))
        self.assertTrue(data['readiness']['termination_witnessed'])
        self.assertEqual(data['diagnostic']['phase'], 'wait')
        self.assertNotIn('private', report.read_text(encoding='utf-8'))
        self.retain_ready_failure('eof', {}, {})
        self.assertEqual(len(list(destination.iterdir())), 1)
        report.unlink()
        sentinel = self.root / 'sentinel'; sentinel.write_bytes(b'unchanged')
        report.symlink_to(sentinel)
        self.retain_ready_failure('eof', {}, {})
        self.assertEqual(sentinel.read_bytes(), b'unchanged')

    def test_success_survives_darwin_permission_race_with_safe_evidence(self):
        # Read a real completed child's output, then inject Darwin's signaling
        # result; actual wait and /bin/ps still verify that no group is running.
        process = subprocess.Popen([sys.executable, '-c', "print('DW_AT_language (DW_LANG_Rust)')"],
                                   stdout=subprocess.PIPE, start_new_session=True)
        process.wait(timeout=3)
        diagnostic = {}
        with mock.patch.object(preparation, 'launch_debug_reader', return_value=process), \
             mock.patch.object(cleanup.os, 'killpg', side_effect=[PermissionError(1, 'private-token'), ProcessLookupError()]):
            self.assertTrue(self.scan('', diagnostic=diagnostic))
        self.assertEqual(diagnostic['cleanup'], 'complete')
        self.assertTrue(diagnostic['cleanup_details']['permission_race_recovered'])
        self.assertNotIn('private', json.dumps(diagnostic))

    def test_retained_cleanup_diagnostics_include_errno_without_process_identity(self):
        detail = {'outcome':'failed', 'phase':'verify', 'group_state':'live', 'reaped':True,
                  'errors':[{'phase':'kill','kind':'permission','errno':1,'message':'private-token'}], 'pid':123}
        preparation.retain_failure_diagnostic('macos_rust_dwarfdump_failed',
                                             [{'phase':'cleanup','cleanup_details':detail}])
        data=json.loads((self.root/'diagnostics/reader-lifecycle.json').read_text())
        actual=data['diagnostics'][0]['cleanup_details']
        self.assertEqual(actual['errors'][0]['errno'],1)
        self.assertNotIn('pid',actual)
        self.assertNotIn('private',json.dumps(data))

    def test_eof_with_delayed_success_preserves_unterminated_rust_attribute(self):
        diagnostic = {}
        source = "import os, time\nos.write(1, b'DW_AT_language (DW_LANG_Rust)')\nos.close(1)\ntime.sleep(.05)\n"
        self.assertTrue(self.scan(source, diagnostic=diagnostic))
        self.assertTrue(diagnostic["eof"])
        self.assertEqual(diagnostic["returncode"], 0)

    def test_unterminated_rust_attribute_after_nonzero_exit_is_incomplete(self):
        diagnostic = {}
        with self.assertRaisesRegex(preparation.PreparationError, "^macos_rust_dwarfdump_incomplete$"):
            self.scan("import sys\nsys.stdout.write('DW_AT_language (DW_LANG_Rust)')\nsys.exit(7)\n",
                      diagnostic=diagnostic)
        self.assertEqual(diagnostic["phase"], "wait")
        self.assertEqual(diagnostic["returncode"], 7)
        self.assertTrue(diagnostic["reaped"])

    def test_descendant_holding_pipe_is_bounded_even_after_leader_exit(self):
        self.ready_timeout('held')

    def test_launch_failure_is_sanitized_and_has_no_cleanup_resource(self):
        diagnostic = {}
        output = io.StringIO()
        with mock.patch.object(preparation.subprocess, "Popen", side_effect=FileNotFoundError("private-token /private/path")), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
             self.assertRaisesRegex(preparation.PreparationError, "^macos_rust_dwarfdump_failed$") as raised:
            self.scan("", diagnostic=diagnostic)
        self.assertEqual(raised.exception.diagnostic, diagnostic)
        self.assertEqual(diagnostic["phase"], "launch")
        self.assertEqual(diagnostic["exception_kind"], "file_not_found")
        self.assertFalse(diagnostic["process_started"])
        self.assertEqual(diagnostic["cleanup"], "not_started")
        self.assertEqual(output.getvalue(), "")
        retained = next((self.root / "diagnostics").glob("failure-*.json")).read_text()
        self.assertNotIn("private", retained)

    def test_selector_and_read_failures_release_pipe_and_reap_child(self):
        for phase, patch in (("selector", mock.patch.object(preparation.selectors, "DefaultSelector",
                                                           side_effect=ValueError("private-token"))),
                             ("read", mock.patch.object(preparation, "read_debug_pipe",
                                                        side_effect=OSError("private-token /private/path")))):
            with self.subTest(phase=phase):
                diagnostic = {}
                # Popen itself uses os.read on its exec-error pipe. Start a real
                # child before injecting the reader failure so launch is intact.
                process = subprocess.Popen([sys.executable, "-c", "print('fixture', flush=True); import time; time.sleep(60)"],
                                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
                with mock.patch.object(preparation, "launch_debug_reader", return_value=process), patch, \
                     self.assertRaisesRegex(preparation.PreparationError, "^macos_rust_dwarfdump_failed$"):
                    self.scan("", diagnostic=diagnostic)
                self.assertEqual(diagnostic["phase"], phase)
                self.assertTrue(diagnostic["reaped"])
                self.assertTrue(diagnostic["pipe_closed"])
                self.assertEqual(diagnostic["cleanup"], "complete")

    def test_cleanup_failure_fails_closed_without_masking_reader_failure(self):
        original = preparation.stop_debug_process
        def cleanup(process):
            original(process)
            raise OSError("private-token /private/path")
        for source, expected, phase in (("print('DW_AT_language (DW_LANG_Rust)')\n", "macos_rust_dwarfdump_failed", "cleanup"),
                                        ("import sys\nsys.exit(7)\n", "macos_rust_dwarfdump_incomplete", "wait")):
            with self.subTest(phase=phase):
                diagnostic = {}
                with mock.patch.object(preparation, "stop_debug_process", side_effect=cleanup), \
                     self.assertRaisesRegex(preparation.PreparationError, "^" + expected + "$"):
                    self.scan(source, diagnostic=diagnostic)
                self.assertEqual(diagnostic["phase"], phase)
                self.assertEqual(diagnostic["cleanup_exception_kind"], "os_error")
                self.assertEqual(diagnostic["cleanup"], "failed")
                self.assertTrue(diagnostic["reaped"])
                self.assertTrue(diagnostic["pipe_closed"])

    def test_cleanup_signal_failure_still_attempts_kill_and_wait(self):
        process = mock.Mock(pid=123, returncode=0)
        with mock.patch.object(preparation.os, "killpg", side_effect=PermissionError(1, "private")) as kill, \
             mock.patch.object(cleanup, "group_state", return_value="live"):
            with self.assertRaises(cleanup.CleanupError):
                preparation.stop_debug_process(process)
        self.assertEqual(kill.call_count, 2)
        self.assertEqual(process.wait.call_count, 2)

    def test_cleanup_wait_failure_still_attempts_kill_and_final_reap(self):
        for failure in (ChildProcessError("private-token /private/path"), OSError("private-token")):
            with self.subTest(kind=type(failure).__name__):
                process = mock.Mock(pid=123, returncode=0)
                process.wait.side_effect = [failure, 0]
                with mock.patch.object(preparation.os, "killpg") as kill, \
                     mock.patch.object(cleanup, "group_state", return_value="gone"), self.assertRaises(cleanup.CleanupError):
                    preparation.stop_debug_process(process)
                self.assertEqual([call.args[1] for call in kill.call_args_list], [signal.SIGTERM, signal.SIGKILL])
                self.assertEqual([call.kwargs["timeout"] for call in process.wait.call_args_list], [.1, .5])

    def test_pipe_close_failure_is_safe_and_fails_closed(self):
        process = subprocess.Popen([sys.executable, "-c", "print('DW_AT_language (DW_LANG_C11)')"],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        original = process.stdout
        class Pipe:
            def __getattr__(self, name):
                return getattr(original, name)
            def close(self):
                original.close()
                raise ValueError("private-token /private/path")
        process.stdout = Pipe()
        diagnostic = {}
        with mock.patch.object(preparation, "launch_debug_reader", return_value=process), \
             self.assertRaisesRegex(preparation.PreparationError, "^macos_rust_dwarfdump_failed$"):
            self.scan("", diagnostic=diagnostic)
        self.assertEqual(diagnostic["phase"], "cleanup")
        self.assertEqual(diagnostic["cleanup_exception_kind"], "value_error")
        self.assertTrue(diagnostic["reaped"])
        self.assertTrue(diagnostic["pipe_closed"])


class MacRustSliceTests(unittest.TestCase):
    """Synthetic Mach-O images exercise real planning without any native tool."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sentry-slices-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.build = self.root / "build"
        self.products = self.build / "macos/Build/Products/Release"
        self.app = self.products / "Fixture.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Fixture"}))
        for target, relative, arches in (("runner", "MacOS/Fixture", ("x86_64",)),
                                         ("rust_api", "Frameworks/rust_api.framework/rust_api", ("x86_64", "arm64")),
                                         ("FlClashCore", "MacOS/FlClashCore", ("x86_64",)),
                                         ("App", "Frameworks/App.framework/App", ("x86_64",))):
            binary = self.app / "Contents" / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            runtime, debug = [], []
            for architecture in arches:
                identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, target + architecture))
                runtime.append((architecture, macho(identifier, architecture, filetype=2 if target == "runner" else 6)))
                debug.append((architecture, macho(identifier, architecture, debug=True, text=False)))
            binary.write_bytes(universal(runtime) if len(runtime) > 1 else runtime[0][1])
            dwarf = self.products / (target + ".dSYM/Contents/Resources/DWARF") / target
            dwarf.parent.mkdir(parents=True)
            dwarf.write_bytes(universal(debug) if len(debug) > 1 else debug[0][1])
        write_inventory(self.build, self.app, "Release", ["pods"], [
            dict(target="rust_api", product="rust_api.framework", source="pods")])
        self.report = self.build / "macos/sentry-symbol-preparation.json"

    def test_each_actual_slice_requires_its_own_language_evidence(self):
        def evidence(_tool, path, *, architecture, **_kwargs):
            self.assertEqual([item["architecture"] for item in preparation.variants(path)], [architecture])
            return architecture == "x86_64"
        with mock.patch.object(preparation, "contains_rust_debug", side_effect=evidence) as reader, \
             mock.patch.object(preparation, "run_dsymutil") as generate, \
             self.assertRaisesRegex(preparation.PreparationError, "^rust_framework_missing_rust_compilation_units$"):
            preparation.Preparer(self.build, dwarfdump="fixture").prepare()
        generate.assert_not_called()
        self.assertEqual({call.kwargs["architecture"] for call in reader.call_args_list}, {"x86_64", "arm64"})
        rows = {row["architecture"]: row for row in json.loads(self.report.read_text())["modules"] if row["target"] == "rust_api"}
        self.assertTrue(rows["x86_64"]["ready"])
        self.assertFalse(rows["arm64"]["ready"])
        self.assertEqual(rows["arm64"]["failure"], "rust_framework_missing_rust_compilation_units")
        self.assertFalse((self.build / "sentry-native/macos/manifest.json").exists())

    def test_unknown_exception_retains_phase_and_safe_kind_after_fixture_cleanup(self):
        retained = self.root / "retained"
        with mock.patch.dict(os.environ, {"SENTRY_MACOS_DIAGNOSTICS_DIR": str(retained)}), \
             mock.patch.object(preparation, "contains_rust_debug", side_effect=RuntimeError("private-token /private/path")), \
             self.assertRaisesRegex(preparation.PreparationError, "^macos_symbol_preparation_failed$"):
            preparation.Preparer(self.build, dwarfdump="fixture").prepare()
        report = json.loads(self.report.read_text())
        self.assertIn(dict(phase="rust_debug", exception_kind="runtime_error"), report["diagnostics"])
        serialized = next(retained.glob("failure-*.json")).read_text()
        self.assertNotIn("private", serialized)
        self.assertNotIn("modules", serialized)
        self.report.unlink()
        self.assertTrue(json.loads(serialized)["diagnostics"])

    def test_reader_launch_failure_survives_preparer_without_generic_fallback(self):
        retained = self.root / "retained"
        with mock.patch.dict(os.environ, {"SENTRY_MACOS_DIAGNOSTICS_DIR": str(retained)}), \
             self.assertRaisesRegex(preparation.PreparationError, "^macos_rust_dwarfdump_failed$"):
            preparation.Preparer(self.build, dwarfdump=str(self.root / "private-missing-tool")).prepare()
        report = json.loads(self.report.read_text())
        self.assertEqual(report["failures"], ["macos_rust_dwarfdump_failed"])
        rows = [row for row in report["modules"] if row["target"] == "rust_api"]
        for row in rows:
            self.assertEqual(row["rust_reader"]["phase"], "launch")
            self.assertEqual(row["rust_reader"]["exception_kind"], "file_not_found")
            self.assertEqual(row["rust_reader"]["architecture"], row["architecture"])
            self.assertFalse(row["ready"])
        serialized = (retained / "reader-lifecycle.json").read_text()
        self.assertNotIn("private", serialized)
        self.assertEqual(len(json.loads(serialized)["diagnostics"]), 2)


class DiagnosticRetentionTests(unittest.TestCase):
    def test_retention_is_bounded_and_only_projects_safe_fields(self):
        with tempfile.TemporaryDirectory() as temporary, \
             mock.patch.dict(os.environ, {"SENTRY_MACOS_DIAGNOSTICS_DIR": temporary}):
            for _ in range(preparation.MAX_RETAINED_DIAGNOSTICS + 3):
                preparation.retain_failure_diagnostic("private-token", [dict(phase="read", exception_kind="os_error",
                    argv="private-token", stderr="private-token", path="/private/path", returncode=7,
                    cleanup="private-token", cleanup_exception_kind="private-token")])
            files = list(Path(temporary).glob("failure-*.json"))
            self.assertEqual(len(files), preparation.MAX_RETAINED_DIAGNOSTICS)
            for path in files:
                self.assertNotIn("private", path.read_text())
                self.assertEqual(json.loads(path.read_text())["failure"], "macos_symbol_preparation_failed")

    def test_ordinary_negative_cases_cannot_overwrite_unexpected_summary(self):
        with tempfile.TemporaryDirectory() as temporary, \
             mock.patch.dict(os.environ, {"SENTRY_MACOS_DIAGNOSTICS_DIR": temporary}):
            preparation.retain_failure_diagnostic("macos_symbol_preparation_failed", [dict(phase="rust_debug", exception_kind="other")])
            preparation.retain_failure_diagnostic("macos_rust_dwarfdump_failed", [dict(phase="launch", exception_kind="file_not_found")])
            for _ in range(preparation.MAX_RETAINED_DIAGNOSTICS + 3):
                preparation.retain_failure_diagnostic("rust_framework_missing_rust_compilation_units", [dict(phase="rust_debug", exception_kind="preparation")])
            unexpected = json.loads((Path(temporary) / "unexpected.json").read_text())
            reader = json.loads((Path(temporary) / "reader-lifecycle.json").read_text())
            self.assertEqual(unexpected["diagnostics"], [dict(phase="rust_debug", exception_kind="other")])
            self.assertEqual(reader["diagnostics"], [dict(phase="launch", exception_kind="file_not_found")])


if __name__ == "__main__":
    unittest.main()
