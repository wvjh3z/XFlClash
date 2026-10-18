"""Gate status regression; tiny in-memory tests, no build or external actions."""
import io
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tool import check_release_workflow as gate


class PreflightResultTests(unittest.TestCase):
    def test_success_requires_executed_tests_and_zero_skips(self):
        def passing():
            pass
        self.assertEqual(gate.run_suite(unittest.TestSuite([unittest.FunctionTestCase(passing)]), stream=io.StringIO()), 0)
        self.assertEqual(gate.run_suite(unittest.TestSuite(), stream=io.StringIO()), 1)

    def test_failure_error_and_skip_cannot_open_the_gate(self):
        def failing():
            raise AssertionError("fixture failure")
        def error():
            raise RuntimeError("fixture error")
        def skipped():
            raise unittest.SkipTest("required fixture skipped")
        for case in (failing, error, skipped):
            with self.subTest(case=case.__name__):
                output = io.StringIO()
                self.assertEqual(gate.run_suite(unittest.TestSuite([unittest.FunctionTestCase(case)]), stream=output), 1)
                self.assertIn('"passed": false', output.getvalue())

    def test_missing_tool_or_non_posix_is_explicit_not_successful_skip(self):
        with mock.patch.object(gate.os, "name", "posix"), mock.patch.object(gate.shutil, "which", side_effect=lambda n: None if n == "git" else "/fixture/"+n):
            self.assertEqual(gate.requirements(), ["git"])
            with mock.patch.object(gate.unittest.defaultTestLoader, "loadTestsFromNames") as loader, mock.patch("sys.stderr", new=io.StringIO()):
                self.assertEqual(gate.main(), 2)
                loader.assert_not_called()
        with mock.patch.object(gate.os, "name", "nt"), mock.patch.object(gate.shutil, "which", return_value="fixture"):
            self.assertTrue(gate.requirements())


if __name__ == "__main__":
    unittest.main()
