#!/usr/bin/env python3
"""Number inputs and real temporary-Git publication races; no builds/network."""
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_build_number as numbers


class NumberTests(unittest.TestCase):
    def test_empty_uses_counter_and_manual_equal_or_larger_is_allowed(self):
        self.assertEqual(numbers.resolve("21", ""), 21)
        self.assertEqual(numbers.resolve("21", "21"), 21)
        self.assertEqual(numbers.resolve("21", "50"), 50)
        self.assertEqual(numbers.resolve("1", ""), 1)

    def test_invalid_and_lower_inputs_fail_before_build(self):
        for value in ("0", "-1", "20", "21.0", " 22", "22 ", "0022", "２２", "22\n",
                      "$(touch unexpected)", "22;exit 0", str(numbers.MAX_BUILD_NUMBER + 1)):
            with self.subTest(value=value), self.assertRaises(numbers.BuildNumberError):
                numbers.resolve("21", value)
        for value in ("", "bad", "0", "21\n"):
            with self.subTest(counter=value), self.assertRaises(numbers.BuildNumberError):
                numbers.resolve(value)

    def test_next_counter_tracks_actual_build_and_never_goes_back(self):
        self.assertEqual(numbers.next_counter("21", "21"), 22)
        self.assertEqual(numbers.next_counter("21", "50"), 51)
        self.assertEqual(numbers.next_counter("60", "50"), 60)
        self.assertEqual(numbers.next_counter("51", "50"), 51)
        exhausted = str(numbers.next_counter(str(numbers.MAX_BUILD_NUMBER), str(numbers.MAX_BUILD_NUMBER)))
        with self.assertRaises(numbers.BuildNumberError):
            numbers.resolve(exhausted)

    def test_cli_outputs_actual_number_without_advancing_source_counter(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            counter = root / "scripts/build_number.brand_a.txt"
            counter.write_text("21\n")
            output, summary = root / "output", root / "summary"
            with mock.patch.dict(os.environ, {"REQUESTED_BUILD_NUMBER": "50", "GITHUB_OUTPUT": str(output),
                                              "GITHUB_STEP_SUMMARY": str(summary)}, clear=True), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(numbers.main(["resolve", "--flavor", "brand_a", "--project-root", str(root)]), 0)
            self.assertEqual(output.read_text(), "build_number=50\n")
            self.assertIn("Build 50", summary.read_text())
            self.assertIn("manual input", summary.read_text())
            self.assertEqual(counter.read_text(), "21\n")
            with mock.patch.dict(os.environ, {"RESOLVED_BUILD_NUMBER": "50"}, clear=True), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(numbers.main(["advance", "--flavor", "brand_a", "--project-root", str(root)]), 0)
            self.assertEqual(counter.read_text(), "51\n")

    def test_cli_rejects_missing_counter_and_never_reflects_untrusted_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(numbers.main(["resolve", "--flavor", "brand_b", "--project-root", str(root)]), 1)
            self.assertNotIn(str(root), errors.getvalue())
            (root / "scripts").mkdir()
            (root / "scripts/build_number.brand_b.txt").write_text("1\n")
            with mock.patch.dict(os.environ, {"REQUESTED_BUILD_NUMBER": "fake-private-input"}, clear=True), \
                 contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(numbers.main(["resolve", "--flavor", "brand_b", "--project-root", str(root)]), 1)
            self.assertNotIn("fake-private-input", errors.getvalue())

    @unittest.skipUnless(shutil.which("git"), "Pinned source validation needs Git")
    def test_cli_checks_pinned_source_before_writing_number_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            counter = root / "scripts/build_number.brand_a.txt"
            counter.write_text("21\n")
            for arguments in (["init", "--initial-branch=main"], ["add", "."],
                              ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                               "commit", "-m", "fixture"]):
                subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True)
            sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            output, summary = root / "output", root / "summary"
            for expected_sha, ref, expected_code in (("a" * 40, "refs/heads/main", 1),
                                                       (sha, "invalid-ref", 1),
                                                       (sha, "refs/heads/main", 0)):
                with self.subTest(source=expected_sha, ref=ref):
                    env = {"BUILD_SOURCE_SHA": expected_sha, "BUILD_SOURCE_REF": ref,
                           "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)}
                    with mock.patch.dict(os.environ, env, clear=True), \
                         contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                        self.assertEqual(numbers.main(["resolve", "--flavor", "brand_a",
                                                       "--project-root", str(root)]), expected_code)
                    if expected_code:
                        self.assertFalse(output.exists())
                        self.assertFalse(summary.exists())
                    else:
                        self.assertEqual(output.read_text(), "build_number=21\n")
                        self.assertIn(sha, summary.read_text())
                        self.assertIn("source snapshot counter", summary.read_text())
                    self.assertEqual(counter.read_text(), "21\n")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash") and shutil.which("git"),
                     "Real isolated Git race uses POSIX shell fixtures")
class PublishCounterTests(unittest.TestCase):
    def test_push_races_recompute_from_latest_main_and_keep_unrelated_commits(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from sentry_release_workflow_test import step_script
        script = step_script("Increment build_number for flavor")
        real_git = shutil.which("git")
        for concurrent_counter in (21, 60):
            with self.subTest(concurrent_counter=concurrent_counter), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                origin, seed, worker, other = (root / name for name in ("origin.git", "seed", "worker", "other"))
                env = {"PATH": os.environ["PATH"], "HOME": str(root), "GIT_CONFIG_NOSYSTEM": "1",
                       "GIT_CONFIG_GLOBAL": os.devnull, "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                       "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}

                def git(*args, cwd=None):
                    return subprocess.check_output([real_git, *args], cwd=cwd, env=env, stderr=subprocess.STDOUT, text=True)

                git("init", "--bare", "--initial-branch=main", str(origin))
                git("init", "--initial-branch=main", str(seed))
                (seed / "scripts").mkdir()
                (seed / "tool").mkdir()
                (seed / "scripts/build_number.brand_a.txt").write_text("21\n")
                (seed / "scripts/build_number.brand_b.txt").write_text("7\n")
                shutil.copy2(Path(numbers.__file__), seed / "tool/release_build_number.py")
                git("add", ".", cwd=seed)
                git("commit", "-m", "fixture", cwd=seed)
                git("remote", "add", "origin", str(origin), cwd=seed)
                git("push", "origin", "main", cwd=seed)
                git("clone", str(origin), str(worker))
                git("clone", str(origin), str(other))
                binary = root / "bin"
                binary.mkdir()
                (root / "runner-temp").mkdir()
                wrapper = binary / "git"
                wrapper.write_text("#!" + sys.executable + "\n" + '''
import os, pathlib, subprocess, sys
args=sys.argv[1:]
real=os.environ['REAL_GIT']
marker=pathlib.Path(os.environ['RACE_MARKER'])
if args==['push','origin','HEAD:main'] and not marker.exists():
    marker.write_text('injected')
    other=pathlib.Path(os.environ['OTHER_CHECKOUT'])
    (other/'scripts/build_number.brand_a.txt').write_text(os.environ['CONCURRENT_COUNTER']+'\\n')
    (other/'independent-change.txt').write_text('must survive')
    for command in (['add','.'],['commit','-m','concurrent change'],['push','origin','main']):
        subprocess.run([real,*command],cwd=other,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
raise SystemExit(subprocess.run([real,*args]).returncode)
''')
                wrapper.chmod(0o755)
                # Avoid actually waiting four seconds after the injected rejection.
                (binary / "sleep").write_text("#!/bin/sh\nexit 0\n")
                (binary / "sleep").chmod(0o755)
                run_env = {**env, "PATH": str(binary) + os.pathsep + env["PATH"], "FLAVOR": "brand_a",
                           "RESOLVED_BUILD_NUMBER": "50", "RUNNER_TEMP": str(root / "runner-temp"),
                           "REAL_GIT": real_git, "RACE_MARKER": str(root / "race"),
                           "OTHER_CHECKOUT": str(other), "CONCURRENT_COUNTER": str(concurrent_counter)}
                result = subprocess.run(["bash", "-c", script], cwd=worker, env=run_env,
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((root / "race").exists())
                expected = max(51, concurrent_counter)
                self.assertEqual(git("show", "main:scripts/build_number.brand_a.txt", cwd=origin).strip(), str(expected))
                self.assertEqual(git("show", "main:scripts/build_number.brand_b.txt", cwd=origin).strip(), "7")
                self.assertEqual(git("show", "main:independent-change.txt", cwd=origin), "must survive")
                count = git("rev-list", "--count", "main", cwd=origin)
                second = subprocess.run(["bash", "-c", script], cwd=worker, env=run_env,
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
                self.assertEqual(git("rev-list", "--count", "main", cwd=origin), count)


if __name__ == "__main__":
    unittest.main()
