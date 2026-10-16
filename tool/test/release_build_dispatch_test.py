#!/usr/bin/env python3
"""Offline dispatch contracts and automatic/manual routing; never call GitHub."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_build_number as numbers


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        self.counter = self.root / "scripts/build_number.brand_a.txt"
        self.counter.write_text("21\n")
        self.output, self.summary = self.root / "output", self.root / "summary"
        self.output.touch()
        self.summary.touch()
        self.env = {"GITHUB_REPOSITORY": numbers.REPOSITORY, "GITHUB_RUN_ID": "100",
                    "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": "a" * 40, "GITHUB_REF": "refs/heads/main",
                    "GITHUB_OUTPUT": str(self.output), "GITHUB_STEP_SUMMARY": str(self.summary),
                    "BUILD_TARGET": "windows-amd64", "RESOLVED_BUILD_NUMBER": "21",
                    "REQUESTED_BUILD_NUMBER": "", "PREPARED_FROM": "", "SDK_REF": "b" * 40,
                    "UPLOAD_PACKAGES": "false", "VERIFY_SYMBOLICATION": "true",
                    "BUILD_DISPATCH_TOKEN": "fixture-dispatch-token"}
        self.child = {"run_id": 101, "html_url": f"https://github.com/{numbers.REPOSITORY}/actions/runs/101"}

    def call(self, action, environment=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, environment or self.env, clear=True), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = numbers.main([action, "--flavor", "brand_a", "--project-root", str(self.root)])
        self.assertNotIn("fixture-dispatch-token", stdout.getvalue() + stderr.getvalue())
        return code, stdout.getvalue(), stderr.getvalue()

    def test_automatic_preparation_dispatches_once_with_exact_options_and_links(self):
        with mock.patch.object(numbers, "send_dispatch", return_value=self.child) as send:
            self.assertEqual(self.call("dispatch")[0], 0)
        send.assert_called_once()
        payload, token = send.call_args.args
        self.assertEqual(token, "fixture-dispatch-token")
        self.assertEqual(payload["ref"], "main")
        self.assertTrue(payload["return_run_details"])
        self.assertEqual(payload["inputs"], {"flavor": "brand_a", "target": "windows-amd64",
            "build_number": "21", "sdk_ref": "b" * 40, "upload": False, "verify_symbolication": True,
            "prepared_from": json.dumps({"run_id": "100", "sha": "a" * 40, "ref": "refs/heads/main"},
                                        sort_keys=True, separators=(",", ":"))})
        self.assertIn("numbered_run_id=101", self.output.read_text())
        self.assertIn(self.child["html_url"], self.summary.read_text())
        self.assertEqual(self.counter.read_text(), "21\n")

    def test_branch_and_tag_refs_are_forwarded_without_creating_remote_refs(self):
        for ref, expected in (("refs/heads/release/test", "release/test"), ("refs/tags/v1.0", "v1.0")):
            with self.subTest(ref=ref), mock.patch.object(numbers, "send_dispatch", return_value=self.child) as send:
                self.assertEqual(self.call("dispatch", {**self.env, "GITHUB_REF": ref})[0], 0)
                self.assertEqual(send.call_args.args[0]["ref"], expected)

    def child_env(self):
        parent = numbers.source_identity(self.env)
        return {**self.env, "GITHUB_RUN_ID": "101", "REQUESTED_BUILD_NUMBER": "21",
                "PREPARED_FROM": json.dumps(parent)}

    def test_numbered_child_resolves_same_number_and_links_to_parent_without_dispatch(self):
        with mock.patch.object(numbers, "send_dispatch") as send:
            self.assertEqual(self.call("resolve", self.child_env())[0], 0)
        send.assert_not_called()
        self.assertEqual(self.output.read_text(), "build_number=21\n")
        self.assertIn("automatic preparation", self.summary.read_text())
        self.assertIn("/actions/runs/100", self.summary.read_text())
        self.assertEqual(self.counter.read_text(), "21\n")

    def test_moved_branch_changed_ref_and_malformed_parent_stop_before_outputs(self):
        child = self.child_env()
        cases = [{**child, "GITHUB_SHA": "c" * 40}, {**child, "GITHUB_REF": "refs/heads/other"},
                 {**child, "PREPARED_FROM": "[]"}, {**child, "PREPARED_FROM": "invalid"},
                 {**child, "GITHUB_RUN_ID": "100"}, {**child, "REQUESTED_BUILD_NUMBER": ""}]
        for env in cases:
            with self.subTest(env=env), mock.patch.object(numbers, "send_dispatch") as send:
                self.assertEqual(self.call("resolve", env)[0], 1)
                send.assert_not_called()
        self.assertEqual(self.output.read_text(), "")
        self.assertEqual(self.counter.read_text(), "21\n")

    def test_numbered_child_and_manual_input_cannot_redispatch(self):
        for env in (self.child_env(), {**self.env, "REQUESTED_BUILD_NUMBER": "50"}):
            with self.subTest(env=env), mock.patch.object(numbers, "send_dispatch") as send:
                self.assertEqual(self.call("dispatch", env)[0], 1)
                send.assert_not_called()

    def test_preparation_rerun_invalid_ref_and_untrusted_repository_never_dispatch(self):
        cases = [{**self.env, "GITHUB_RUN_ATTEMPT": "2"}, {**self.env, "GITHUB_REPOSITORY": "other/repo"},
                 {**self.env, "GITHUB_REF": "refs/heads/main\n"}, {**self.env, "SDK_REF": "../bad"},
                 {**self.env, "UPLOAD_PACKAGES": "False"}, {**self.env, "RESOLVED_BUILD_NUMBER": ""},
                 {**self.env, "BUILD_TARGET": "unknown"}]
        for env in cases:
            with self.subTest(env=env), mock.patch.object(numbers, "send_dispatch") as send:
                self.assertEqual(self.call("dispatch", env)[0], 1)
                send.assert_not_called()

    def test_post_failure_is_not_retried_and_does_not_advance_counter(self):
        with mock.patch.object(numbers, "send_dispatch", side_effect=numbers.BuildNumberError("ambiguous dispatch")) as send:
            self.assertEqual(self.call("dispatch")[0], 1)
        send.assert_called_once()
        self.assertEqual(self.counter.read_text(), "21\n")

    def test_transport_is_fixed_no_redirect_and_returns_verified_child_url(self):
        result = {"workflow_run_id": 101, "html_url": self.child["html_url"],
                  "run_url": f"https://api.github.com/repos/{numbers.REPOSITORY}/actions/runs/101"}
        response = mock.MagicMock(status=200)
        response.__enter__.return_value = response
        response.read.return_value = json.dumps(result).encode()
        opener = mock.Mock()
        opener.open.return_value = response
        payload = {"ref": "main", "return_run_details": True, "inputs": {"build_number": "21"}}
        with mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener) as build:
            self.assertEqual(numbers.send_dispatch(payload, "fixture-dispatch-token"), self.child)
        self.assertIsInstance(build.call_args.args[0], numbers.NoRedirect)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, numbers.DISPATCH_URL)
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.get_header("X-github-api-version"), "2022-11-28")
        self.assertEqual(json.loads(request.data), payload)
        opener.open.assert_called_once()
        self.assertIsNone(numbers.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))

    def test_transport_rejects_ambiguous_empty_or_foreign_responses_without_retry(self):
        cases = [(204, b""), (200, b"{}"), (200, b"bad"), (200, b"x" * 65537),
                 (200, json.dumps({"workflow_run_id": 101, "html_url": "https://other.invalid", "run_url": "bad"}).encode())]
        for status, body in cases:
            with self.subTest(status=status, body=body[:20]):
                response = mock.MagicMock(status=status)
                response.__enter__.return_value = response
                response.read.return_value = body
                opener = mock.Mock()
                opener.open.return_value = response
                with mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener), \
                     self.assertRaises(numbers.BuildNumberError):
                    numbers.send_dispatch({}, "fixture-dispatch-token")
                opener.open.assert_called_once()
        for error in (TimeoutError("fake-private-body"), urllib.error.HTTPError(numbers.DISPATCH_URL, 403, "fake-private-body", {}, None)):
            opener = mock.Mock()
            opener.open.side_effect = error
            with mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener), \
                 self.assertRaises(numbers.BuildNumberError) as raised:
                numbers.send_dispatch({}, "fixture-dispatch-token")
            self.assertNotIn("fake-private-body", str(raised.exception))
            opener.open.assert_called_once()

    def test_missing_token_never_makes_a_request(self):
        with mock.patch.object(numbers.urllib.request, "build_opener") as build, self.assertRaises(numbers.BuildNumberError):
            numbers.send_dispatch({}, "")
        build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
