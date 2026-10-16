#!/usr/bin/env python3
"""Offline credential isolation tests; no real SDK, network or Keychain access."""

import base64
import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkout_sibling_sdk as sdk

TOKEN = "fixture-sdk-token-never-real"
ENCODED = base64.b64encode(("x-access-token:" + TOKEN).encode()).decode()


class CheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sdk-checkout-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / "client"
        self.workspace.mkdir()
        self.destination = self.root / "Xboard_sdk"
        self.environment = {"PATH": os.environ.get("PATH", os.defpath),
                            "GITHUB_WORKSPACE": str(self.workspace), "SDK_READ_TOKEN": TOKEN}
        for key in ("SYSTEMROOT", "SystemRoot", "WINDIR", "COMSPEC"):
            if key in os.environ:
                self.environment[key] = os.environ[key]

    def call(self, environment=None, ref="a" * 40):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = sdk.main(["--destination", str(self.destination), "--ref", ref],
                            environment=environment or self.environment)
        for secret in (TOKEN, ENCODED):
            self.assertNotIn(secret, output.getvalue() + errors.getvalue())
        return code, output.getvalue(), errors.getvalue()

    def test_exact_commands_keep_credentials_out_of_argv_and_detach_environment(self):
        environment = {**self.environment, "GIT_CONFIG_COUNT": "99", "GIT_CONFIG_VALUE_98": TOKEN,
                       "GIT_CONFIG_PARAMETERS": TOKEN, "GIT_TRACE": str(self.root / "trace"),
                       "GIT_CONFIG_GLOBAL": TOKEN, "GIT_CONFIG_SYSTEM": TOKEN, "GIT_EXEC_PATH": TOKEN,
                       "GIT_CURL_VERBOSE": "1", "GIT_ASKPASS": "bad-prompt", "SSH_ASKPASS": "bad-prompt",
                       "SENTRY_AUTH_TOKEN": "other-fixture-token", "GITHUB_TOKEN": "other-fixture-token"}
        previous = dict(environment)
        calls = []
        with mock.patch.object(sdk.shutil, "which", return_value="git"), \
             mock.patch.object(sdk, "run_phase", side_effect=lambda *args: calls.append(args)):
            code, _, _ = self.call(environment)
        self.assertEqual(code, 0)
        self.assertEqual(environment, previous)
        self.assertEqual([call[1] for call in calls], ["clone", "fetch", "checkout"])
        self.assertEqual(calls[0][0], ["git", "clone", "--no-checkout", "--depth", "1",
                                       sdk.REPOSITORY, str(self.destination)])
        self.assertEqual(calls[1][0], ["git", "-C", str(self.destination), "fetch", "--depth", "1", "origin", "a" * 40])
        self.assertEqual(calls[2][0][-3:], ["checkout", "--detach", "FETCH_HEAD"])
        for arguments, _, child, _ in calls:
            self.assertNotIn(TOKEN, json.dumps(arguments))
            self.assertNotIn(ENCODED, json.dumps(arguments))
            for key in ("SDK_READ_TOKEN", "SENTRY_AUTH_TOKEN", "GITHUB_TOKEN", "GIT_TRACE",
                        "GIT_CURL_VERBOSE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_VALUE_98",
                        "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_EXEC_PATH"):
                self.assertNotIn(key, child)
            self.assertEqual(child["GIT_TERMINAL_PROMPT"], "0")
            self.assertEqual(child["GIT_ASKPASS"], "")
            self.assertEqual(child["SSH_ASKPASS"], "")
        self.assertEqual(calls[0][2]["GIT_CONFIG_VALUE_0"], "")
        self.assertEqual(calls[0][2]["GIT_CONFIG_VALUE_2"], "")
        self.assertNotIn(ENCODED, json.dumps(calls[2][2]))
        self.assertFalse((self.root / "trace").exists())

    def test_invalid_input_and_existing_destination_never_start_git(self):
        with mock.patch.object(sdk, "run_phase") as phase:
            for ref in ("-o", "bad\nref", "../other", "a b"):
                with self.subTest(ref=ref):
                    self.assertEqual(self.call(ref=ref)[0], 1)
            self.destination.mkdir()
            self.assertEqual(self.call()[0], 1)
        phase.assert_not_called()

    def test_wrong_sibling_and_missing_token_fail_without_reflection(self):
        self.destination = self.root / "elsewhere"
        self.assertIn("sdk_sibling_destination_required", self.call()[2])
        self.destination = self.root / "Xboard_sdk"
        environment = {key: value for key, value in self.environment.items() if key != "SDK_READ_TOKEN"}
        self.assertIn("sdk_read_token_required_or_invalid", self.call(environment)[2])

    def test_failed_child_cannot_echo_token_header_or_url_into_logs(self):
        child = self.root / "failing.py"
        child.write_text("import os,sys,base64\n"
                         "header=os.environ['GIT_CONFIG_VALUE_1']\n"
                         "secret=base64.b64decode(header.split()[-1]).decode()\n"
                         "print(header);print(secret,file=sys.stderr)\n"
                         "print('https://'+secret+'@github.com/',file=sys.stderr)\n"
                         "raise SystemExit(7)\n")
        original = sdk.run_phase
        def run(arguments, phase, environment, timeout):
            original([sys.executable, str(child)], phase, environment, timeout)
        with mock.patch.object(sdk.shutil, "which", return_value="git"), \
             mock.patch.object(sdk, "run_phase", side_effect=run):
            code, _, errors = self.call()
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(errors), {"status": "failed", "phase": "clone",
                                             "code": "git_nonzero_exit", "exit_code": 7})
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(TOKEN.encode(), path.read_bytes())
                self.assertNotIn(ENCODED.encode(), path.read_bytes())

    def test_timeout_is_fixed_phase_code_and_child_is_reaped(self):
        started = time.monotonic()
        with self.assertRaises(sdk.CheckoutError) as failure:
            sdk.run_phase([sys.executable, "-c", "import time;time.sleep(60)"],
                          "fetch", sdk.clean_environment(self.environment), 0.05)
        self.assertEqual((failure.exception.phase, failure.exception.code), ("fetch", "git_timeout"))
        self.assertLess(time.monotonic() - started, 20)


@unittest.skipUnless(shutil.which("git"), "Offline Git executable required")
class RealGitIsolationTests(unittest.TestCase):
    call = CheckoutTests.call

    def setUp(self):
        CheckoutTests.setUp(self)
        self.git = shutil.which("git")
        self.home = self.root / "home"
        self.home.mkdir()
        self.environment.update(HOME=str(self.home), USERPROFILE=str(self.home),
                                XDG_CONFIG_HOME=str(self.home / "xdg"))
        self.base_environment = {key: value for key, value in sdk.clean_environment(self.environment).items()
                                 if not key.startswith("GIT_CONFIG_")}
        self.events = self.root / "helper-events"
        helper = self.root / "helper.py"
        helper.write_text("import pathlib,sys\n"
                          "sys.stdin.read()\n"
                          "with pathlib.Path(sys.argv[1]).open('a') as out:\n"
                          " out.write(sys.argv[2]+':'+sys.argv[-1]+'\\n')\n")
        self.invoke(["config", "--global", "credential.helper", ""])
        for name in ("first", "second"):
            command = "!" + shlex.join([Path(sys.executable).as_posix(), helper.as_posix(), self.events.as_posix(), name])
            self.invoke(["config", "--global", "--add", "credential.helper", command])

    def invoke(self, arguments, *, environment=None, input=None, check=True):
        return subprocess.run([self.git, *arguments], env=environment or self.base_environment, cwd=self.workspace,
                              input=input, text=True, capture_output=True, check=check, timeout=20)

    def test_approve_baseline_calls_both_helpers_and_empty_chain_disables_all_operations(self):
        credential = "protocol=https\nhost=github.com\nusername=fixture\npassword=" + TOKEN + "\n\n"
        self.invoke(["credential", "approve"], input=credential)
        self.assertEqual(self.events.read_text().splitlines(), ["first:store", "second:store"])
        self.events.unlink()
        isolated = sdk.authentication_environment(self.environment, TOKEN)
        for operation in ("approve", "reject"):
            self.invoke(["credential", operation], environment=isolated, input=credential)
        fill = self.invoke(["credential", "fill"], environment=isolated,
                           input="protocol=https\nhost=github.com\n\n", check=False)
        self.assertNotEqual(fill.returncode, 0)
        self.assertFalse(self.events.exists())

    def test_repository_scoped_header_resets_all_inherited_values(self):
        for value in ("Authorization: old-one", "Authorization: old-two"):
            self.invoke(["config", "--global", "--add", sdk.HEADER_KEY, value])
        result = self.invoke(["config", "--get-urlmatch", "http.extraheader", sdk.REPOSITORY],
                             environment=sdk.authentication_environment(self.environment, TOKEN))
        self.assertEqual([line for line in result.stdout.splitlines() if line],
                         ["AUTHORIZATION: basic " + ENCODED])
        unrelated = self.invoke(["config", "--get-urlmatch", "http.extraheader",
                                 "https://github.com/getsentry/sentry-cocoa.git"],
                                environment=sdk.authentication_environment(self.environment, TOKEN), check=False)
        self.assertNotIn(ENCODED, unrelated.stdout)
        after = self.invoke(["config", "--get-urlmatch", "http.extraheader", sdk.REPOSITORY])
        self.assertNotIn(ENCODED, after.stdout)
        self.assertFalse(self.events.exists())

    def test_real_local_clone_fetch_detach_keeps_origin_and_files_secret_free(self):
        source, bare = self.root / "origin-source", self.root / "origin.git"
        self.invoke(["init", str(source)])
        (source / "sdk.dart").write_text("// offline fixture\n")
        self.invoke(["-C", str(source), "add", "sdk.dart"])
        self.invoke(["-C", str(source), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                     "commit", "-m", "fixture"])
        ref = self.invoke(["-C", str(source), "rev-parse", "HEAD"]).stdout.strip()
        self.invoke(["clone", "--bare", str(source), str(bare)])
        self.invoke(["config", "--global", "url." + bare.as_uri() + ".insteadOf", sdk.REPOSITORY])
        self.assertEqual(self.call(ref=ref)[0], 0)
        actual = self.invoke(["-C", str(self.destination), "rev-parse", "HEAD"]).stdout.strip()
        self.assertEqual(actual, ref)
        self.assertNotEqual(self.invoke(["-C", str(self.destination), "symbolic-ref", "HEAD"], check=False).returncode, 0)
        origin = self.invoke(["config", "--file", str(self.destination / ".git/config"), "--get", "remote.origin.url"]).stdout.strip()
        self.assertEqual(origin, sdk.REPOSITORY)
        for directory in (self.home, self.destination):
            for path in directory.rglob("*"):
                if path.is_file():
                    content = path.read_bytes()
                    self.assertNotIn(TOKEN.encode(), content)
                    self.assertNotIn(ENCODED.encode(), content)
        self.assertFalse(self.events.exists())


if __name__ == "__main__":
    unittest.main()
