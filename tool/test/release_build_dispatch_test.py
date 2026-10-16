#!/usr/bin/env python3
"""Offline repository dispatch and preparation/source contracts; no network."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_build_number as numbers
import release_request as requests


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
        self.env = {"GITHUB_REPOSITORY": numbers.REPOSITORY, "GITHUB_EVENT_NAME": "workflow_dispatch",
                    "GITHUB_RUN_ID": "100", "GITHUB_RUN_NUMBER": "75", "GITHUB_RUN_ATTEMPT": "1",
                    "GITHUB_SHA": "a" * 40, "GITHUB_REF": "refs/heads/main",
                    "GITHUB_OUTPUT": str(self.output), "GITHUB_STEP_SUMMARY": str(self.summary),
                    "BUILD_TARGET": "windows-amd64", "RESOLVED_BUILD_NUMBER": "21",
                    "REQUESTED_BUILD_NUMBER": "", "PREPARED_FROM": "", "UPLOAD_PACKAGES": "false",
                    "BUILD_DISPATCH_TOKEN": "fixture-dispatch-token"}
        self.child = {"run_id": 101, "html_url": f"https://github.com/{numbers.REPOSITORY}/actions/runs/101"}

    def call(self, action, environment=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, environment or self.env, clear=True), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = numbers.main([action, "--flavor", "brand_a", "--project-root", str(self.root)])
        self.assertNotIn("fixture-dispatch-token", stdout.getvalue() + stderr.getvalue())
        return code, stdout.getvalue(), stderr.getvalue()

    def origin(self):
        return numbers.source_identity(self.env)

    def child_env(self):
        return {**self.env, "GITHUB_EVENT_NAME": "repository_dispatch", "GITHUB_RUN_ID": "101",
                "GITHUB_RUN_NUMBER": "76", "GITHUB_SHA": "b" * 40, "GITHUB_REF": "refs/heads/default-moved",
                "REQUESTED_BUILD_NUMBER": "21", "PREPARED_FROM": json.dumps(self.origin()),
                "BUILD_SOURCE_SHA": "a" * 40, "BUILD_SOURCE_REF": "refs/heads/main"}

    def run_record(self, **changes):
        return {"id": 101, "event": "repository_dispatch", "path": ".github/workflows/release-package.yml@main",
                "display_title": "brand_a · windows-amd64 · build 21 · 准备 #75",
                "html_url": self.child["html_url"],
                "url": f"https://api.github.com/repos/{numbers.REPOSITORY}/actions/runs/101", **changes}

    def response(self, status, content):
        response = mock.MagicMock(status=status)
        response.__enter__.return_value = response
        response.read.return_value = content
        return response

    def test_automatic_preparation_posts_exact_payload_once_then_links_unique_child(self):
        with mock.patch.object(numbers, "send_dispatch") as send, \
             mock.patch.object(numbers, "find_numbered_build", return_value=self.child) as find:
            self.assertEqual(self.call("dispatch")[0], 0)
        send.assert_called_once_with({"event_type": numbers.EVENT_TYPE, "client_payload": {
            "flavor": "brand_a", "target": "windows-amd64", "build_number": "21", "upload": False,
            "origin": self.origin()}}, "fixture-dispatch-token")
        find.assert_called_once_with("brand_a · windows-amd64 · build 21 · 准备 #75", "fixture-dispatch-token")
        self.assertIn("numbered_run_id=101", self.output.read_text())
        self.assertIn(self.child["html_url"], self.summary.read_text())
        self.assertEqual(self.counter.read_text(), "21\n")

    def test_branch_and_tag_refs_are_payload_metadata_and_sdk_probe_are_not_sent(self):
        for ref in ("refs/heads/release/test", "refs/tags/v1.0"):
            env = {**self.env, "GITHUB_REF": ref, "SDK_REF": "private-do-not-forward",
                   "VERIFY_SYMBOLICATION": "private-do-not-forward", "UPLOAD_PACKAGES": "true"}
            with self.subTest(ref=ref), mock.patch.object(numbers, "send_dispatch") as send, \
                 mock.patch.object(numbers, "find_numbered_build", return_value=self.child):
                self.assertEqual(self.call("dispatch", env)[0], 0)
                payload = send.call_args.args[0]
                self.assertEqual(payload["client_payload"]["origin"]["ref"], ref)
                self.assertTrue(payload["client_payload"]["upload"])
                self.assertNotIn("private-do-not-forward", json.dumps(payload))
                self.assertNotIn("fixture-dispatch-token", json.dumps(payload))
                self.assertEqual(set(payload), {"event_type", "client_payload"})

    def test_internal_child_resolves_pinned_source_even_when_default_branch_moved(self):
        with mock.patch.object(numbers, "send_dispatch") as send, \
             mock.patch.object(requests, "check_source_checkout") as check:
            self.assertEqual(self.call("resolve", self.child_env())[0], 0)
        check.assert_called_once_with(self.root, "a" * 40)
        send.assert_not_called()
        self.assertEqual(self.output.read_text(), "build_number=21\n")
        summary = self.summary.read_text()
        self.assertIn("automatic preparation", summary)
        self.assertIn("/actions/runs/100", summary)
        self.assertIn("Preparation run #75", summary)
        self.assertIn("a" * 40, summary)
        self.assertNotIn("b" * 40, summary)
        self.assertEqual(self.counter.read_text(), "21\n")

    def test_bad_origin_or_changed_pinned_source_stops_before_outputs(self):
        child = self.child_env()
        bad_origins = ("[]", "invalid", json.dumps({**self.origin(), "extra": "bad"}),
                       json.dumps({k: v for k, v in self.origin().items() if k != "run_number"}))
        cases = [{**child, "BUILD_SOURCE_SHA": "c" * 40}, {**child, "BUILD_SOURCE_REF": "refs/heads/other"},
                 {**child, "GITHUB_RUN_ID": "100"}, {**child, "REQUESTED_BUILD_NUMBER": ""},
                 {**child, "GITHUB_EVENT_NAME": "workflow_dispatch"}, {**child, "PREPARED_FROM": ""}]
        cases += [{**child, "PREPARED_FROM": origin} for origin in bad_origins]
        for env in cases:
            with self.subTest(env=env), mock.patch.object(numbers, "send_dispatch") as send, \
                 mock.patch.object(requests, "check_source_checkout"):
                self.assertEqual(self.call("resolve", env)[0], 1)
                send.assert_not_called()
        self.assertEqual(self.output.read_text(), "")
        self.assertEqual(self.counter.read_text(), "21\n")

    def test_child_manual_number_preparation_rerun_and_bad_source_never_redispatch(self):
        cases = [self.child_env(), {**self.env, "REQUESTED_BUILD_NUMBER": "50"},
                 {**self.env, "GITHUB_RUN_ATTEMPT": "2"}, {**self.env, "GITHUB_REPOSITORY": "other/repo"},
                 {**self.env, "GITHUB_EVENT_NAME": "repository_dispatch"},
                 {**self.env, "GITHUB_EVENT_NAME": "push"}, {**self.env, "GITHUB_REF": "refs/heads/main\n"},
                 {**self.env, "GITHUB_RUN_NUMBER": ""}, {**self.env, "UPLOAD_PACKAGES": "False"},
                 {**self.env, "RESOLVED_BUILD_NUMBER": ""}, {**self.env, "BUILD_TARGET": "unknown"},
                 {**self.env, "BUILD_SOURCE_SHA": "c" * 40}, {**self.env, "BUILD_SOURCE_REF": "refs/tags/other"}]
        for env in cases:
            with self.subTest(env=env), mock.patch.object(numbers, "send_dispatch") as send:
                self.assertEqual(self.call("dispatch", env)[0], 1)
                send.assert_not_called()

    def test_missing_actions_paths_stop_before_post(self):
        for path in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY"):
            with self.subTest(path=path), mock.patch.object(numbers, "send_dispatch") as send:
                self.assertEqual(self.call("dispatch", {**self.env, path: str(self.root / "missing")})[0], 1)
                send.assert_not_called()

    def test_post_failure_is_not_retried_and_never_starts_discovery_or_advances_counter(self):
        with mock.patch.object(numbers, "send_dispatch", side_effect=numbers.BuildNumberError("ambiguous dispatch")) as send, \
             mock.patch.object(numbers, "find_numbered_build") as find:
            self.assertEqual(self.call("dispatch")[0], 1)
        send.assert_called_once()
        find.assert_not_called()
        self.assertEqual(self.counter.read_text(), "21\n")

    def test_accepted_but_unlocated_run_reports_uncertainty_without_reposting(self):
        with mock.patch.object(numbers, "send_dispatch") as send, \
             mock.patch.object(numbers, "find_numbered_build", return_value=None):
            code, stdout, _ = self.call("dispatch")
        self.assertEqual(code, 0)
        send.assert_called_once()
        self.assertIn("not yet confirmed", stdout)
        self.assertEqual(self.output.read_text(), "")
        self.assertIn(numbers.WORKFLOW_URL, self.summary.read_text())
        self.assertIn("不要重跑", self.summary.read_text())

    def test_transport_fixed_post_accepts_only_204_and_never_redirects(self):
        opener = mock.Mock()
        opener.open.return_value = self.response(204, b"")
        payload = {"event_type": numbers.EVENT_TYPE, "client_payload": {"build_number": "21"}}
        with mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener) as build:
            self.assertIsNone(numbers.send_dispatch(payload, "fixture-dispatch-token"))
        self.assertIsInstance(build.call_args.args[0], numbers.NoRedirect)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, numbers.DISPATCH_URL)
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.get_header("X-github-api-version"), "2022-11-28")
        self.assertEqual(json.loads(request.data), payload)
        opener.open.assert_called_once()
        self.assertIsNone(numbers.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))

    def test_post_rejects_ambiguous_responses_without_retry_or_private_error_content(self):
        for status, body in ((200, b"{}"), (202, b""), (302, b""), (204, b"unexpected")):
            with self.subTest(status=status):
                opener = mock.Mock()
                opener.open.return_value = self.response(status, body)
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

    def test_missing_or_invalid_token_never_makes_a_request(self):
        for token in ("", "token\n", "x" * 4097):
            with self.subTest(token=token[:10]), mock.patch.object(numbers.urllib.request, "build_opener") as build, \
                 self.assertRaises(numbers.BuildNumberError):
                numbers.send_dispatch({}, token)
            build.assert_not_called()

    def test_discovery_filters_exact_title_and_event_and_validates_run_links(self):
        title = self.run_record()["display_title"]
        runs = [self.run_record(display_title="other title"), self.run_record(event="workflow_dispatch"), self.run_record()]
        opener = mock.Mock()
        opener.open.return_value = self.response(200, json.dumps({"workflow_runs": runs}).encode())
        with mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener) as build:
            self.assertEqual(numbers.find_numbered_build(title, "fixture-dispatch-token"), self.child)
        self.assertIsInstance(build.call_args.args[0], numbers.NoRedirect)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, numbers.WORKFLOW_RUNS_URL + "?event=repository_dispatch&per_page=100")
        self.assertEqual(request.method, "GET")
        self.assertLessEqual(opener.open.call_args.kwargs["timeout"], 4)
        opener.open.assert_called_once()

    def test_discovery_only_retries_gets_and_stops_after_three(self):
        opener = mock.Mock()
        opener.open.return_value = self.response(200, b'{"workflow_runs":[]}')
        with mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener):
            self.assertIsNone(numbers.find_numbered_build("title", "fixture-dispatch-token"))
        self.assertEqual(opener.open.call_count, 3)
        self.assertTrue(all(call.args[0].method == "GET" for call in opener.open.call_args_list))
        opener.open.reset_mock()
        opener.open.side_effect = [TimeoutError("private-value"), self.response(200, json.dumps({"workflow_runs": [self.run_record()]}).encode())]
        with mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(numbers.find_numbered_build(self.run_record()["display_title"], "fixture-dispatch-token"), self.child)
        self.assertEqual(opener.open.call_count, 2)

    def test_discovery_ambiguous_foreign_and_malformed_results_do_not_create_links(self):
        good = self.run_record()
        cases = [[good, good], [self.run_record(html_url="https://other.invalid")],
                 [self.run_record(url="https://other.invalid")], [self.run_record(path="other.yml")],
                 [self.run_record(id=True)], [self.run_record(id=0)], [self.run_record(path=None)]]
        for runs in cases:
            opener = mock.Mock()
            opener.open.return_value = self.response(200, json.dumps({"workflow_runs": runs}).encode())
            with self.subTest(runs=runs), mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener):
                self.assertIsNone(numbers.find_numbered_build(good["display_title"], "fixture-dispatch-token"))
        for status, body in ((403, b"private-value"), (200, b"{}"), (200, b"bad"), (200, b"[]"),
                             (200, b"x" * 1_048_577)):
            opener = mock.Mock()
            opener.open.return_value = self.response(status, body)
            with self.subTest(status=status, body=body[:10]), mock.patch.object(numbers.urllib.request, "build_opener", return_value=opener):
                self.assertIsNone(numbers.find_numbered_build(good["display_title"], "fixture-dispatch-token"))
            self.assertLessEqual(opener.open.call_count, 3)

    def test_discovery_obeys_total_budget(self):
        with mock.patch.object(numbers.time, "monotonic", side_effect=[0, 13]), \
             mock.patch.object(numbers.urllib.request, "build_opener") as build:
            self.assertIsNone(numbers.find_numbered_build("title", "fixture-dispatch-token"))
        build.assert_not_called()

    def test_actual_checkout_mismatch_prevents_number_outputs(self):
        subprocess.run(["git", "init", "--initial-branch=main"], cwd=self.root,
                       check=True, capture_output=True)
        subprocess.run(["git", "add", "scripts"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-m", "fixture"], cwd=self.root, check=True, capture_output=True)
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip()
        child = self.child_env()
        self.assertEqual(self.call("resolve", child)[0], 1)
        self.assertEqual(self.output.read_text(), "")
        origin = {**self.origin(), "sha": sha}
        self.assertEqual(self.call("resolve", {**child, "PREPARED_FROM": json.dumps(origin), "BUILD_SOURCE_SHA": sha})[0], 0)
        self.assertEqual(self.output.read_text(), "build_number=21\n")


if __name__ == "__main__":
    unittest.main()
