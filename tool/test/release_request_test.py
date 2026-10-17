#!/usr/bin/env python3
"""Offline native-event, pinned policy and exact-source release contracts."""
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_request as requests


class RequestTests(unittest.TestCase):
    def setUp(self):
        self.env = {"GITHUB_REPOSITORY": requests.REPOSITORY, "GITHUB_EVENT_NAME": "workflow_dispatch",
                    "GITHUB_SHA": "a" * 40, "GITHUB_REF": "refs/heads/main"}
        self.inputs = {"flavor": "brand_a", "target": "windows-amd64", "build_number": "", "upload": "false"}

    def test_empty_manual_number_and_explicit_number_share_one_request_path(self):
        actual = requests.normalize({"inputs": self.inputs}, self.env)
        self.assertEqual(actual, {"flavor": "brand_a", "target": "windows-amd64", "requested_number": "",
            "upload": "false", "source_sha": "a" * 40, "source_ref": "refs/heads/main"})
        actual = requests.normalize({"inputs": {**self.inputs, "build_number": "65535", "upload": True}}, self.env)
        self.assertEqual(actual["upload"], "true")
        self.assertEqual(actual["requested_number"], "65535")

    def test_omitted_empty_and_null_number_all_use_automatic_numbering(self):
        omitted = {key: value for key, value in self.inputs.items() if key != "build_number"}
        for values in (omitted, self.inputs, {**self.inputs, "build_number": None}):
            with self.subTest(values=values):
                actual = requests.normalize({"inputs": values}, self.env)
                self.assertEqual(actual["requested_number"], "")
                self.assertEqual(actual["target"], "windows-amd64")

    def test_missing_fields_use_the_workflow_defaults(self):
        expected = {"flavor": "brand_a", "target": "android", "requested_number": "", "upload": "false",
                    "source_sha": "a" * 40, "source_ref": "refs/heads/main"}
        for event in ({"inputs": {}}, {}):
            with self.subTest(event=event):
                self.assertEqual(requests.normalize(event, self.env), expected)
        defaults = {"flavor": "brand_a", "target": "android", "build_number": "", "upload": False}
        for field in defaults:
            with self.subTest(missing=field):
                values = {key: value for key, value in defaults.items() if key != field}
                self.assertEqual(requests.normalize({"inputs": values}, self.env), expected)
        actual = requests.normalize({"inputs": {"flavor": "brand_b", "upload": "true"}}, self.env)
        self.assertEqual((actual["flavor"], actual["target"], actual["upload"]), ("brand_b", "android", "true"))

    def test_branch_and_tag_source_refs(self):
        for ref in ("refs/heads/release/test", "refs/tags/v1.0.0"):
            with self.subTest(ref=ref):
                actual = requests.normalize({"inputs": self.inputs}, {**self.env, "GITHUB_REF": ref})
                self.assertEqual(actual["source_ref"], ref)

    def test_all_target_choices_and_both_brands(self):
        for target in requests.TARGETS:
            for flavor in requests.FLAVORS:
                actual = requests.normalize({"inputs": {**self.inputs, "target": target, "flavor": flavor}}, self.env)
                self.assertEqual((actual["target"], actual["flavor"]), (target, flavor))

    def test_public_schema_rejects_removed_and_unknown_fields_or_invalid_containers(self):
        for field in ("prepared_from", "origin", "sdk_ref", "verify_symbolication", "unknown"):
            with self.subTest(field=field), self.assertRaises(requests.RequestError):
                requests.normalize({"inputs": {**self.inputs, field: "private-untrusted"}}, self.env)
        for values in (None, [], "", False):
            with self.subTest(inputs=values), self.assertRaises(requests.RequestError):
                requests.normalize({"inputs": values}, self.env)
        for event in (None, [], "", False):
            with self.subTest(event=event), self.assertRaises(requests.RequestError):
                requests.normalize(event, self.env)

    def test_invalid_choices_numbers_and_upload_types_are_rejected(self):
        for key, bad_values in {"flavor": ["other", "", None, [], False],
            "target": ["unknown", "", {}, None, False],
            "build_number": [False, True, 21, [], {}, "0", "-1", "21.0", "21\n", "0021", "65536", " 21", "２１", "$(id)"],
            "upload": ["False", "TRUE", "1", "", 0, 1, None, [], {}]}.items():
            for value in bad_values:
                with self.subTest(key=key, value=value), self.assertRaises(requests.RequestError):
                    requests.normalize({"inputs": {**self.inputs, key: value}}, self.env)

    def test_internal_and_other_events_are_rejected(self):
        internal = {"action": "xflclash_numbered_release_v1", "client_payload": {**self.inputs,
                    "build_number": "21", "upload": False,
                    "origin": {"run_id": "100", "run_number": "75", "sha": "a" * 40, "ref": "refs/heads/main"}}}
        for kind in ("repository_dispatch", "push", "", None):
            with self.subTest(kind=kind), self.assertRaises(requests.RequestError):
                requests.normalize(internal, {**self.env, "GITHUB_EVENT_NAME": kind})

    def test_source_sha_and_refs_are_strict_and_do_not_depend_on_run_identity(self):
        for key, bad_values in {"GITHUB_SHA": ["A" * 40, "a" * 39, None, "bad"],
            "GITHUB_REF": ["main", "refs/heads/", "refs/tags/", "refs/heads/a\n", "refs/heads/.bad",
                    "refs/heads/a..b", "refs/heads/a.lock", "refs/heads/a@{b", "refs/heads/a//b", None]}.items():
            for value in bad_values:
                with self.subTest(key=key, value=value), self.assertRaises(requests.RequestError):
                    requests.normalize({"inputs": self.inputs}, {**self.env, key: value})
        with self.assertRaises(requests.RequestError):
            requests.normalize({"inputs": self.inputs}, {**self.env, "GITHUB_REPOSITORY": "other/repo"})
        self.assertEqual(requests.normalize({"inputs": self.inputs}, self.env)["source_sha"], "a" * 40)

    def test_cli_native_event_outputs_and_fixed_redacted_errors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            event, output = root / "event.json", root / "output"
            event.write_text(json.dumps({"inputs": self.inputs}))
            env = {**self.env, "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output)}
            with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(requests.main(["normalize"]), 0)
            self.assertEqual(output.read_text(), "flavor=brand_a\ntarget=windows-amd64\nrequested_number=\nupload=false\n"
                             + "source_sha=" + "a" * 40 + "\nsource_ref=refs/heads/main\n")
            for values, message in (({**self.inputs, "target": "fixture-private-input"}, "Invalid release brand or target"),
                                    ({**self.inputs, "build_number": "fixture-private-input"},
                                     "Build number must be an integer from 1 to 65535"),
                                    ({**self.inputs, "fixture-private-input": "secret"}, "Invalid public release input fields")):
                output.write_text("")
                event.write_text(json.dumps({"inputs": values}))
                with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(requests.main(["normalize"]), 1)
                self.assertEqual(errors.getvalue(), "Release request: " + message + "\n")
                self.assertEqual(output.read_text(), "")

    def test_json_reader_rejects_duplicate_keys_oversize_and_invalid_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "event.json"
            for content in ('{"inputs":{},"inputs":{}}', "x" * 65537, "invalid", "\ud800"):
                with self.subTest(content=content[:30]):
                    path.write_bytes(content.encode("utf-8", errors="surrogatepass"))
                    with self.assertRaises(requests.RequestError):
                        requests.read_json(path)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "tool").mkdir()
        self.path = self.root / "tool/release-config.json"
        self.policy = {"sdk_ref": "711e30dbd7a8553631193e4e7e62578f7af037af", "verify_symbolication": False}
        self.path.write_text(json.dumps(self.policy))
        def git(*args):
            return subprocess.check_output(["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                *args], cwd=self.root, stderr=subprocess.DEVNULL, text=True).strip()
        git("init", "--initial-branch=main")
        git("add", ".")
        git("commit", "-m", "fixture")
        self.sha = git("rev-parse", "HEAD")
        self.env = {"BUILD_SOURCE_SHA": self.sha}

    def test_policy_reads_source_config_at_exact_checkout(self):
        self.assertEqual(requests.config(self.root, self.env), {"sdk_ref": self.policy["sdk_ref"], "verify_symbolication": "false"})
        requests.check_source_checkout(self.root, self.sha)

    def test_missing_or_changed_source_sha_stops_before_config_read(self):
        for env in ({}, {"BUILD_SOURCE_SHA": "a" * 40}, {"BUILD_SOURCE_SHA": "bad"}):
            with self.subTest(env=env), mock.patch.object(requests, "read_json") as read, self.assertRaises(requests.RequestError):
                requests.config(self.root, env)
            read.assert_not_called()

    def test_fixed_sdk_commit_or_explicit_tag_accepted_but_floating_branches_rejected(self):
        for sdk in ("a" * 40, "refs/tags/v1.2.3"):
            self.path.write_text(json.dumps({**self.policy, "sdk_ref": sdk}))
            self.assertEqual(requests.config(self.root, self.env)["sdk_ref"], sdk)
        for sdk in ("main", "master", "HEAD", "refs/heads/main", "refs/tags/", "refs/tags/../bad", None, "a" * 39):
            self.path.write_text(json.dumps({**self.policy, "sdk_ref": sdk}))
            with self.subTest(sdk=sdk), self.assertRaises(requests.RequestError):
                requests.config(self.root, self.env)

    def test_exact_policy_schema_and_boolean_probe_required(self):
        for policy in ({}, [], {**self.policy, "other": False},
                       {**self.policy, "verify_symbolication": "false"}, {**self.policy, "verify_symbolication": 0}):
            self.path.write_text(json.dumps(policy))
            with self.subTest(policy=policy), self.assertRaises(requests.RequestError):
                requests.config(self.root, self.env)
        self.path.write_text(json.dumps({**self.policy, "verify_symbolication": True}))
        self.assertEqual(requests.config(self.root, self.env)["verify_symbolication"], "true")

    def test_config_cli_outputs_both_policy_values_only(self):
        output = self.root / "output"
        with mock.patch.dict(os.environ, {**self.env, "GITHUB_OUTPUT": str(output)}, clear=True), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(requests.main(["config", "--project-root", str(self.root)]), 0)
        self.assertEqual(output.read_text(), f"sdk_ref={self.policy['sdk_ref']}\nverify_symbolication=false\n")


if __name__ == "__main__":
    unittest.main()
