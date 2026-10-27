#!/usr/bin/env python3
"""Exercise release sequencing and failure recovery using temporary fake projects.

No Flutter, Go core build, network upload, signing or real APK is invoked.
"""

from __future__ import annotations

import contextlib
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from crisp_resource_fixture import resource_dump
import build_android_local as android
import postbuild_sentry_symbols as postbuild


def pem_certificate(certificate):
    return '-----BEGIN CERTIFICATE-----\n' + base64.b64encode(certificate).decode() + '\n-----END CERTIFICATE-----\n'


class CertificateOutputTests(unittest.TestCase):
    def test_legacy_and_scheme_labels_use_certificate_bytes(self):
        certificate = b'public certificate fixture'
        digest = hashlib.sha256(certificate).hexdigest()
        for label in ('Signer #1', 'V2 Signer:', 'V3.1 Signer:'):
            with self.subTest(label=label):
                output = label + ' certificate SHA-256 digest: ' + '0'*64 + '\r\n' + pem_certificate(certificate)
                self.assertEqual(android.apk_certificate_sha256(output), digest)

    def test_repeated_scheme_certificate_is_same_identity(self):
        pem = pem_certificate(b'public certificate fixture')
        self.assertEqual(android.apk_certificate_sha256(pem + pem),
                         android.apk_certificate_sha256(pem))

    def test_missing_malformed_empty_or_different_certificates_fail(self):
        valid = pem_certificate(b'public certificate fixture')
        for output in ('Signer #1 certificate SHA-256 digest: ' + 'a'*64,
                       '-----BEGIN CERTIFICATE-----\n!bad!\n-----END CERTIFICATE-----',
                       pem_certificate(b''), valid + '-----BEGIN CERTIFICATE-----',
                       valid + pem_certificate(b'different certificate')):
            with self.subTest(output=output), self.assertRaises(android.ReleaseError):
                android.apk_certificate_sha256(output)


class LocalCounterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "scripts").mkdir()
        self.ci = self.root / "scripts/build_number.brand_a.txt"
        self.ci.write_text("21\n")

    def test_migration_is_once_and_other_brands_are_independent(self):
        self.assertEqual(android.read_local_build_number(self.root, "brand_a"), 21)
        android.write_local_build_number(self.root, "brand_a", 50)
        self.ci.write_text("22\n")
        self.assertEqual(android.read_local_build_number(self.root, "brand_a"), 50)
        self.ci.unlink()
        self.assertEqual(android.read_local_build_number(self.root, "brand_a"), 50)
        (self.root / "scripts/build_number.brand_b.txt").write_text("1\n")
        self.assertEqual(android.read_local_build_number(self.root, "brand_b"), 1)
        self.assertEqual(android.read_local_build_number(self.root, "brand_a"), 50)

    def test_corrupt_local_counter_is_not_reset_from_ci(self):
        android.read_local_build_number(self.root, "brand_a")
        counter = android.local_counter_path(self.root, "brand_a")
        for value in ("", "-1", "0", "1.5", "bad", "2100000001"):
            with self.subTest(value=value):
                counter.write_text(value)
                with self.assertRaises(android.ReleaseError):
                    android.read_local_build_number(self.root, "brand_a")
                self.assertEqual(counter.read_text(), value)
        self.assertEqual(self.ci.read_text(), "21\n")

    def test_missing_seed_and_invalid_brand_fail_without_creating_counter(self):
        self.ci.unlink()
        with self.assertRaises(android.ReleaseError):
            android.read_local_build_number(self.root, "brand_a")
        self.assertFalse((self.root / ".local-build").exists())
        with self.assertRaises(android.ReleaseError):
            android.local_counter_path(self.root, "../brand_a")

    def test_failed_atomic_replace_keeps_previous_local_number(self):
        android.read_local_build_number(self.root, "brand_a")
        with mock.patch.object(Path, "replace", side_effect=OSError("fixture failure")), self.assertRaises(OSError):
            android.write_local_build_number(self.root, "brand_a", 50)
        self.assertEqual(android.read_local_build_number(self.root, "brand_a"), 21)
        self.assertEqual(len(list((self.root / ".local-build").iterdir())), 1)
        self.assertEqual(self.ci.read_text(), "21\n")

    @unittest.skipIf(os.name == "nt", "Symbolic-link fixture requires POSIX")
    def test_local_path_cannot_alias_the_tracked_counter(self):
        (self.root / ".local-build").symlink_to(self.root / "scripts", target_is_directory=True)
        with self.assertRaises(android.ReleaseError):
            android.read_local_build_number(self.root, "brand_a")
        (self.root / ".local-build").unlink()
        (self.root / ".local-build").mkdir()
        (self.root / ".local-build/build_number.brand_a.txt").symlink_to(self.ci)
        with self.assertRaises(android.ReleaseError):
            android.write_local_build_number(self.root, "brand_a", 50)
        self.assertEqual(self.ci.read_text(), "21\n")

    @unittest.skipUnless(shutil.which("git"), "Git required for real index isolation fixture")
    def test_git_add_all_excludes_local_number_and_retains_ci_number(self):
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, capture_output=True)
        source = Path(__file__).resolve().parents[2] / ".gitignore"
        (self.root / ".gitignore").write_bytes(source.read_bytes())
        android.read_local_build_number(self.root, "brand_a")
        android.write_local_build_number(self.root, "brand_a", 50)
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True, capture_output=True)
        staged = subprocess.check_output(["git", "diff", "--cached", "--name-only"], cwd=self.root, text=True).splitlines()
        self.assertEqual(set(staged), {".gitignore", "scripts/build_number.brand_a.txt"})
        self.assertEqual(subprocess.check_output(["git", "show", ":scripts/build_number.brand_a.txt"], cwd=self.root, text=True), "21\n")
        subprocess.run(["git", "check-ignore", "--quiet", ".local-build/build_number.brand_a.txt"], cwd=self.root, check=True)


class WorkingSourceFingerprintTests(unittest.TestCase):
    def test_new_hook_is_bound_but_ignored_credentials_are_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary);root=base/'client';sdk=base/'sdk';core=root/'core/Clash.Meta'
            for repo,source in [(root,'lib/main.dart'),(sdk,'lib/sdk.dart'),(core,'main.go')]:
                repo.mkdir(parents=True,exist_ok=True)
                subprocess.run(['git','init','--quiet','--template=',str(repo)],check=True)
                (repo/'.gitignore').write_text('*.secret\ncore/Clash.Meta/\n')
                path=repo/source;path.parent.mkdir(exist_ok=True);path.write_text('tracked input')
                subprocess.run(['git','add','.'],cwd=repo,check=True)
                subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgSign=false','commit','--quiet','-m','fixture'],cwd=repo,check=True)
            flavor=root/'flavors/brand_a';(flavor/'assets').mkdir(parents=True)
            (flavor/'flavor.yaml').write_text('public fixture');(flavor/'assets/fallback.bin').write_bytes(b'fixture')
            added=root/'plugins/rust_api/hook/xboard_symbols.dart';added.parent.mkdir(parents=True);added.write_text('new hook')
            ignored=root/'lib/credential.secret';ignored.write_text('never include')
            # Stale deleted-submodule directories must not become phantom repos.
            (root/'plugins/tray_manager').mkdir();(root/'plugins/flutter_distributor').mkdir()
            snapshot=android.capture_sources(root,sdk,'brand_a')
            self.assertIn('plugins/rust_api/hook/xboard_symbols.dart',snapshot['client']['files'])
            self.assertNotIn('lib/credential.secret',snapshot['client']['files'])
            added.write_text('changed hook')
            with self.assertRaises(android.ReleaseError):android.assert_sources(root,sdk,'brand_a',snapshot)


class CliOutputEncodingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cli-encoding-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "\u6d4b\u8bd5 \u5de5\u5177"
        self.root.mkdir()
        self.cli = self.root / "sentry \u7248\u672c.py"
        self.environment = dict(os.environ)
        self.real_run = subprocess.run

    def write_cli(self, stdout, stderr, code=0):
        # ASCII source, explicit raw UTF-8/invalid-byte output: unaffected by
        # PYTHONIOENCODING and the child's locale. No real CLI/token/upload.
        self.cli.write_text(
            'import sys\nassert sys.argv[1:] == ["--version"]\n'
            f'sys.stdout.buffer.write({stdout!r})\n'
            f'sys.stderr.buffer.write({stderr!r})\n'
            f'sys.exit({code})\n', encoding="utf-8")

    def launch(self, argv, **kwargs):
        self.assertEqual(argv, [str(self.cli), "--version"])
        self.assertEqual(kwargs.get("timeout"), 30)
        # Replace only the executable boundary with Python, then use real pipes
        # and real decoding. Model the Windows default when encoding is omitted.
        kwargs.setdefault("encoding", "cp1252")
        return self.real_run([sys.executable, *argv], **kwargs)

    def resolve(self):
        with mock.patch.object(postbuild.shutil, "which", return_value=str(self.cli)), \
                mock.patch.object(postbuild.subprocess, "run", side_effect=self.launch):
            return postbuild.resolve_cli(str(self.cli), self.environment)

    def test_real_child_under_chinese_path_accepts_utf8_diagnostics_and_crlf(self):
        diagnostic = "\u5de5\u5177\u8def\u5f84\u63d0\u793a\uff1a\u6d4b\u8bd5\u0081\n".encode("utf-8")
        self.write_cli(b"sentry-cli 2.58.4\r\n", diagnostic)
        # Capture real bytes, then reproduce the wrong codec in this thread.
        # Windows Popen decodes pipes in reader threads; assertRaises around
        # subprocess.run would not see a reader-thread UnicodeDecodeError.
        raw = self.real_run([sys.executable, str(self.cli), "--version"],
                            capture_output=True, env=self.environment, timeout=30)
        self.assertEqual(raw.returncode, 0)
        self.assertEqual(raw.stdout, b"sentry-cli 2.58.4\r\n")
        self.assertEqual(raw.stderr, diagnostic)
        self.assertEqual(raw.stderr.decode("utf-8").encode("utf-8"), diagnostic)
        with self.assertRaises(UnicodeDecodeError):
            raw.stderr.decode("cp1252")
        self.assertEqual(self.resolve(), str(self.cli))

    def test_non_utf8_stderr_does_not_hide_valid_ascii_version(self):
        self.write_cli(b"sentry-cli 2.58.4\n", b"\xff\x81")
        self.assertEqual(self.resolve(), str(self.cli))

    def test_bad_version_invalid_stdout_and_nonzero_exit_remain_rejected(self):
        for stdout, code in ((b"sentry-cli 2.99.0\n", 0),
                             (b"sentry-cli 2.58.4\xff\n", 0),
                             (b"sentry-cli 2.58.4\n", 7)):
            with self.subTest(stdout=stdout, exit=code):
                self.write_cli(stdout, b"\xff\x81", code)
                with self.assertRaises(postbuild.ReleaseError) as failure:
                    self.resolve()
                self.assertNotIn(str(self.root), str(failure.exception))


class PostbuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "flavors").mkdir()
        (self.root / "flavors/sentry-cli.token").write_text("fake-upload-token\n")
        self.defines = self.root / "flavor_defines.json"
        self.defines.write_text(json.dumps({"XB_FLAVOR_ID": "brand_a", "XB_DEBUG": "false", "XB_SENTRY_DSN": "https://example.invalid/1"}))
        self.arguments = ["--project-root", str(self.root), "--platform", "android", "--flavor", "brand_a"]

    def test_preflight_requires_no_symbols_and_does_not_start_subcommands(self):
        with mock.patch.object(postbuild, "prepare_windows_assets"), mock.patch.object(postbuild, "resolve_cli", return_value="fake-cli"), mock.patch.object(postbuild, "run_checked") as run:
            self.assertEqual(postbuild.main([*self.arguments, "--preflight"]), 0)
        run.assert_not_called()

    def test_missing_upload_credential_fails_before_preparation(self):
        (self.root / "flavors/sentry-cli.token").unlink()
        with mock.patch.dict(os.environ, {"SENTRY_MAINTENANCE_TOKEN": "fake-maintenance"}, clear=True), mock.patch.object(postbuild, "run_checked") as run:
            self.assertEqual(postbuild.main([*self.arguments, "--package", "final.apk"]), 1)
        run.assert_not_called()

    def test_offline_audit_never_reads_or_propagates_upload_token(self):
        with mock.patch.dict(os.environ, {"SENTRY_AUTH_TOKEN": "fake-env-token", "SENTRY_MAINTENANCE_TOKEN": "fake-maintenance"}, clear=True):
            environment = postbuild.upload_environment(self.root, dict(os.environ), True)
        self.assertNotIn("SENTRY_AUTH_TOKEN", environment)
        self.assertNotIn("SENTRY_MAINTENANCE_TOKEN", environment)

    def test_no_sentry_is_an_explicit_skip_without_reading_private_configuration(self):
        self.defines.unlink()
        with mock.patch.object(postbuild, "resolve_cli") as cli, mock.patch.object(postbuild, "upload_environment") as tokens:
            self.assertEqual(postbuild.main([*self.arguments, "--no-sentry"]), 0)
        cli.assert_not_called()
        tokens.assert_not_called()

    def test_token_environment_wins_over_file_and_file_supports_private_location(self):
        self.assertEqual(postbuild.upload_environment(self.root, {"SENTRY_AUTH_TOKEN": "existing"}, False)["SENTRY_AUTH_TOKEN"], "existing")
        secret = self.root / "private.token"
        secret.write_text("private-value\n")
        self.assertEqual(postbuild.upload_environment(self.root, {"SENTRY_AUTH_TOKEN_FILE": str(secret)}, False)["SENTRY_AUTH_TOKEN"], "private-value")

    def test_invalid_token_file_fails_safely(self):
        (self.root / "flavors/sentry-cli.token").write_text("token with spaces")
        with self.assertRaises(postbuild.ReleaseError) as failure:
            postbuild.upload_environment(self.root, {}, False)
        self.assertNotIn("token with spaces", str(failure.exception))

    def test_no_dsn_skips_without_reading_credentials_or_cli(self):
        self.defines.write_text(json.dumps({"XB_FLAVOR_ID": "brand_a", "XB_DEBUG": "false", "XB_SENTRY_DSN": ""}))
        with mock.patch.object(postbuild, "upload_environment") as upload, mock.patch.object(postbuild, "resolve_cli") as cli:
            self.assertEqual(postbuild.main(self.arguments), 0)
        upload.assert_not_called()
        cli.assert_not_called()

    def test_wrong_flavor_and_test_config_are_rejected(self):
        for field, value in (("XB_FLAVOR_ID", "brand_b"), ("XB_DEBUG", "true")):
            with self.subTest(field=field):
                config = {"XB_FLAVOR_ID": "brand_a", "XB_DEBUG": "false", "XB_SENTRY_DSN": "configured"}
                config[field] = value
                self.defines.write_text(json.dumps(config))
                self.assertEqual(postbuild.main(self.arguments), 1)

    def test_all_platforms_route_to_their_preparation_and_audit(self):
        def write_evidence(command, **_kwargs):
            if command[1].endswith("upload_sentry_symbols.py"):
                path = self.root / "build/sentry-symbols-evidence.json"
                path.parent.mkdir(exist_ok=True)
                platform = command[command.index("--platform") + 1]
                path.write_text(json.dumps({"status": "audited", "platform": platform, "flavor": "brand_a"}))
        for platform in postbuild.PLATFORMS:
            with self.subTest(platform=platform), mock.patch.object(postbuild, "prepare_windows_assets"), mock.patch.object(postbuild, "resolve_cli", return_value="fixed-cli"), mock.patch.object(postbuild, "run_checked", side_effect=write_evidence) as run:
                arguments = ["--project-root", str(self.root), "--platform", platform, "--flavor", "brand_a", "--audit-only"]
                if platform == "android":
                    arguments += ["--package", "final-a.apk", "--package", "final-b.apk"]
                self.assertEqual(postbuild.main(arguments), 0)
                calls = [call.args[0] for call in run.call_args_list]
                self.assertEqual(len(calls), 1 if platform == "windows" else 2)
                if platform == "macos":
                    self.assertTrue(calls[0][1].endswith("prepare_sentry_macos_symbols.py"))
                if platform == "android":
                    self.assertEqual(calls[0].count("--package"), 2)
                self.assertTrue(calls[-1][1].endswith("upload_sentry_symbols.py"))
                self.assertIn("--audit-only", calls[-1])
                self.assertIn("fixed-cli", calls[-1])
                for call in run.call_args_list:
                    self.assertNotIn("SENTRY_AUTH_TOKEN", call.kwargs["environment"])

    def test_expected_abis_forwarded_to_preparer_for_both_brands(self):
        for brand in ('brand_a', 'brand_b'):
            self.defines.write_text(json.dumps({'XB_FLAVOR_ID': brand, 'XB_DEBUG': 'false', 'XB_SENTRY_DSN': 'fixture'}))
            arguments = ['--project-root', str(self.root), '--platform', 'android', '--flavor', brand,
                         '--package', 'arm.apk', '--package', 'arm64.apk',
                         '--expected-abi', 'armeabi-v7a', '--expected-abi', 'arm64-v8a']
            with mock.patch.object(postbuild, 'resolve_cli', return_value='fixture'), mock.patch.object(
                    postbuild, 'run_checked', side_effect=postbuild.ReleaseError('controlled stop')) as run:
                self.assertEqual(postbuild.main(arguments), 1)
            command = run.call_args.args[0]
            self.assertEqual([command[i+1] for i,x in enumerate(command) if x == '--expected-abi'],
                             ['armeabi-v7a', 'arm64-v8a'])
            self.assertEqual(run.call_count, 1)

    def test_prepare_failure_prevents_upload(self):
        with mock.patch.object(postbuild, "prepare_windows_assets"), mock.patch.object(postbuild, "resolve_cli", return_value="fake-cli"), mock.patch.object(postbuild, "run_checked", side_effect=postbuild.ReleaseError("prepared failed")) as run:
            self.assertEqual(postbuild.main([*self.arguments, "--package", "final.apk"]), 1)
        self.assertEqual(run.call_count, 1)

    def test_failure_report_lifecycle_for_both_brands_and_all_platforms(self):
        evidence = self.root / 'build/sentry-symbols-evidence.json'
        evidence.parent.mkdir(exist_ok=True)
        for flavor in ('brand_a', 'brand_b'):
            for platform in postbuild.PLATFORMS:
                for phase in ('configuration', 'credentials', 'cli', 'prepare', 'upload', 'completion'):
                    with self.subTest(flavor=flavor, platform=platform, phase=phase):
                        identity = dict(platform=platform, flavor=flavor)
                        evidence.write_text(json.dumps(dict(identity, status='uploaded_and_processed', obsolete=True)))
                        config = dict(XB_FLAVOR_ID=flavor, XB_DEBUG='false', XB_SENTRY_DSN='fixture')
                        if phase == 'configuration': config['XB_DEBUG'] = 'true'
                        self.defines.write_text(json.dumps(config))
                        def fail(): raise postbuild.ReleaseError('controlled failure')
                        def run(command, **kwargs):
                            preparing = 'prepare_sentry_' in command[1]
                            if preparing:
                                if phase == 'prepare': fail()
                            elif phase == 'upload':
                                evidence.write_text(json.dumps(dict(identity, status='failed', upload={'category':'fixture'})))
                                fail()
                        def windows(*_):
                            if phase == 'prepare': fail()
                        with mock.patch.object(postbuild, 'upload_environment', side_effect=(lambda *_: fail()) if phase == 'credentials' else (lambda *_: {})), \
                             mock.patch.object(postbuild, 'resolve_cli', side_effect=(lambda *_: fail()) if phase == 'cli' else (lambda *_: 'fixture')), \
                             mock.patch.object(postbuild, 'prepare_windows_assets', side_effect=windows), \
                             mock.patch.object(postbuild, 'run_checked', side_effect=run):
                            args = ['--project-root', str(self.root), '--flavor', flavor, '--platform', platform, '--package', 'fixture.apk']
                            self.assertEqual(postbuild.main(args), 1)
                        result = json.loads(evidence.read_text())
                        self.assertEqual(result['status'], 'failed')
                        self.assertEqual(result['postbuild_stage'], phase)
                        self.assertNotIn('obsolete', result)
                        if phase == 'upload': self.assertEqual(result['upload']['category'], 'fixture')
                        self.assertFalse(list(evidence.parent.glob('.sentry-outcome-*')))

    def test_preflight_preserves_archive_and_skips_cannot_claim_old_success(self):
        evidence = self.root / 'build/sentry-symbols-evidence.json'
        evidence.parent.mkdir()
        old = b'{"status":"uploaded_and_processed","archive":true}'
        for flags in (['--preflight'], ['--preflight', '--no-sentry']):
            evidence.write_bytes(old)
            with mock.patch.object(postbuild, 'resolve_cli', return_value='fixture'):
                self.assertEqual(postbuild.main([*self.arguments, *flags]), 0)
            self.assertEqual(evidence.read_bytes(), old)
        evidence.write_bytes(old)
        self.defines.unlink()
        self.assertEqual(postbuild.main([*self.arguments, '--preflight']), 1)
        self.assertEqual(evidence.read_bytes(), old)
        self.assertEqual(postbuild.main([*self.arguments, '--no-sentry']), 0)
        self.assertEqual(json.loads(evidence.read_text())['status'], 'skipped')

    def test_reuse_prepared_failure_invalidates_success_without_preparing_again(self):
        evidence = self.root / 'build/sentry-symbols-evidence.json'
        evidence.parent.mkdir()
        evidence.write_text('{"status":"uploaded_and_processed"}')
        with mock.patch.object(postbuild, 'resolve_cli', return_value='fixture'), \
             mock.patch.object(postbuild, 'prepare_windows_assets') as prepare, \
             mock.patch.object(postbuild, 'run_checked', side_effect=postbuild.ReleaseError('controlled')) as run:
            self.assertEqual(postbuild.main([*self.arguments, '--audit-only', '--reuse-prepared']), 1)
        prepare.assert_not_called()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(json.loads(evidence.read_text())['postbuild_stage'], 'audit')

    def test_cli_version_is_pinned(self):
        with mock.patch.object(postbuild.shutil, "which", return_value="fake-cli"), mock.patch.object(postbuild.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="sentry-cli 2.99.0\n")):
            with self.assertRaises(postbuild.ReleaseError):
                postbuild.resolve_cli(None, {})

    def test_stale_completion_report_cannot_replace_upload_confirmation(self):
        evidence = self.root / "build/sentry-symbols-evidence.json"
        evidence.parent.mkdir()
        evidence.write_text(json.dumps({"status": "uploaded_and_processed", "platform": "android", "flavor": "brand_a"}))
        with mock.patch.object(postbuild, "prepare_windows_assets"), mock.patch.object(postbuild, "resolve_cli", return_value="fixed-cli"), mock.patch.object(postbuild, "run_checked"):
            self.assertEqual(postbuild.main([*self.arguments, "--package", "final.apk"]), 1)
        self.assertEqual(json.loads(evidence.read_text())["status"], "failed")

    def test_reuse_prepared_audits_archive_without_regenerating_it(self):
        def complete(command, **_kwargs):
            evidence = self.root / "build/sentry-symbols-evidence.json"
            evidence.parent.mkdir(exist_ok=True)
            evidence.write_text(json.dumps({"status": "audited", "platform": "android", "flavor": "brand_a"}))
        with mock.patch.object(postbuild, "prepare_windows_assets"), mock.patch.object(postbuild, "resolve_cli", return_value="fake-cli"), mock.patch.object(postbuild, "run_checked", side_effect=complete) as run:
            self.assertEqual(postbuild.main([*self.arguments, "--reuse-prepared", "--audit-only"]), 0)
        self.assertEqual(run.call_count, 1)
        self.assertTrue(run.call_args.args[0][1].endswith("upload_sentry_symbols.py"))


def minimal_aot(machine=183, text=b"code", rodata=b"data"):
    names = b"\0.shstrtab\0.text\0.rodata\0"
    sections = [(0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                (1, 3, 0, 0, 64, len(names), 0, 0, 1, 0),
                (11, 1, 6, 0, 64 + len(names), len(text), 0, 0, 1, 0),
                (17, 1, 2, 0, 64 + len(names) + len(text), len(rodata), 0, 0, 1, 0)]
    offset = 64 + len(names) + len(text) + len(rodata)
    identity = b"\x7fELF\x02\x01\x01" + b"\0" * 9
    header = identity + struct.pack("<HHIQQQIHHHHHH", 3, machine, 1, 0, 0, offset, 0, 64, 0, 0, 64, 4, 1)
    return header + names + text + rodata + b"".join(struct.pack("<IIQQQQIIQQ", *section) for section in sections)


class AndroidLocalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "client"
        self.sdk = self.base / "Xboard_sdk"
        for directory in (self.root / "android/app", self.root / "flavors/brand_a/assets", self.root / "scripts", self.root / "lib", self.root / "core/Clash.Meta", self.sdk / "lib"):
            directory.mkdir(parents=True)
        (self.root / "pubspec.yaml").write_text("version: 0.8.93+123\n    # xboard-fallback-assets:begin\n    - flavors/brand_a/assets/\n    # xboard-fallback-assets:end\n")
        (self.root / "pubspec.lock").write_text("client lock")
        (self.sdk / "pubspec.lock").write_text("SDK lock")
        (self.root / "lib/source.dart").write_text("original client source")
        (self.sdk / "lib/source.dart").write_text("original SDK source")
        (self.root / "core/Clash.Meta/core.go").write_text("original core source")
        (self.root / "flavors/brand_a/flavor.yaml").write_text("versionName: '0.0.1'\nappId: com.example.test\nappName: Test Brand\nupdatePackageName: test\n")
        (self.root / "flavors/brand_a/assets/fallback.bin").write_bytes(b"fake-fallback")
        self.ci_counter = self.root / "scripts/build_number.brand_a.txt"
        self.ci_counter.write_text("17\n")
        self.counter = self.root / ".local-build/build_number.brand_a.txt"
        self.properties = self.root / "android/local.properties"
        self.properties.write_text("sdk.dir=/original\nXB_TARGET_ABI=x86_64\n")
        self.keystore = self.root / "android/app/keystore.jks"
        self.keystore.write_bytes(b"original-keystore")
        self.gradle_home = self.base / "gradle"
        (self.gradle_home / "init.d").mkdir(parents=True)
        self.existing_init = self.gradle_home / "init.d/user.gradle"
        self.existing_init.write_text("user-owned")
        self.batch = self.base / "batch"
        self.calls = []
        self.arguments = ["release", "arm64", "brand_a", "--project-root", str(self.root), "--batch-dir", str(self.batch), "--build-tag", "202610152300"]

    def run_fake(self, failure=None, arguments=None, change_source_at=None, change_head_at=None, invalid_evidence=False, change_pubspec_at=None):
        owner = self
        head = "a" * 40
        def run(builder, command, name, cwd=None):
            nonlocal head
            owner.calls.append((name, command, cwd))
            if name == change_head_at:
                head = "b" * 40
            if name == change_source_at:
                (owner.root / "lib/source.dart").write_text("changed during build")
            if name == change_pubspec_at:
                spec=owner.root/'pubspec.yaml'
                spec.write_text(spec.read_text().replace('0.8.93+123','0.9.0+456'))
            if name == failure:
                raise android.ReleaseError("fake failure at " + name)
            if name == "prepare-flavor":
                spec = owner.root / "pubspec.yaml"
                spec.write_text(spec.read_text().replace('flavors/brand_a/assets/', 'flavors/brand_a/assets/fallback.bin'))
                owner.properties.write_text("sdk.dir=/original\nstorePassword=fake\nkeyAlias=fake\nXB_TARGET_ABI=arm64-v8a\n")
                owner.keystore.write_bytes(b"selected-brand-keystore")
                (owner.root / "flavor_defines.json").write_text(json.dumps({"XB_SENTRY_DSN": "configured"}))
            if name == "flutter-apk":
                mode = "debug" if "--debug" in command else "release"
                apk = owner.root / f"build/app/outputs/flutter-apk/app-brand_a-{mode}.apk"
                apk.parent.mkdir(parents=True, exist_ok=True)
                apk.write_bytes(b"fake-apk")
            if name == "sentry-symbols":
                evidence = {"status": "audited" if "--audit-only" in command else "uploaded_and_processed",
                            "platform": "android", "flavor": "brand_a", "product_version": "0.0.1", "build_number": command[command.index("--build-number") + 1], "source_revision": "a" * 40}
                if invalid_evidence:
                    evidence["build_number"] = "17"
                (owner.batch / "sentry-symbols-evidence.json").write_text(json.dumps(evidence))
        def git_output(command, cwd=None, text=False, encoding=None):
            if text:
                self.assertEqual(encoding, "utf-8")
            if command[1] == "rev-parse":
                return head
            repository = Path(cwd)
            names = ("pubspec.yaml\0pubspec.lock\0lib/source.dart\0" if repository == owner.root else "pubspec.lock\0lib/source.dart\0" if repository == owner.sdk else "core.go\0")
            return names.encode()
        with mock.patch.dict(os.environ, {"ANDROID_HOME": str(self.base / "android-sdk"), "ANDROID_NDK": "fake-ndk", "GRADLE_USER_HOME": str(self.gradle_home)}, clear=True), mock.patch.object(android.shutil, "which", return_value="fake-tool"), mock.patch.object(android, "android_tools", return_value=self.base), mock.patch.object(android.subprocess, "check_output", side_effect=git_output), mock.patch.object(android.LocalBuild, "run", run), mock.patch.object(android, "verify_apk", return_value={"signatureVerified": True}), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return android.main(arguments or self.arguments)

    def assert_restored(self, ci_number="17"):
        self.assertIn('- flavors/brand_a/assets/\n', (self.root / 'pubspec.yaml').read_text())
        self.assertNotIn('assets/fallback.bin', (self.root / 'pubspec.yaml').read_text())
        self.assertEqual(self.ci_counter.read_text(), ci_number + "\n")
        self.assertEqual(self.properties.read_text(), "sdk.dir=/original\nXB_TARGET_ABI=x86_64\n")
        self.assertEqual(self.keystore.read_bytes(), b"original-keystore")
        self.assertEqual(list((self.gradle_home / "init.d").iterdir()), [self.existing_init])
        self.assertFalse((self.root / "android/.xfl-local-build.lock").exists())

    def test_release_finishes_only_after_verification_and_symbols(self):
        self.assertEqual(self.run_fake(), 0)
        self.assertEqual([name for name, *_ in self.calls], ["native-inputs", "sdk-pub-get", "clean", "pub-get", "prepare-flavor", "sentry-preflight", "flutter-apk", "sentry-symbols"])
        self.assertEqual(self.counter.read_text(), "18\n")
        self.assertTrue((self.root / "dist/test-0.0.1-android-arm64-v8a.apk").is_file())
        self.assert_restored()
        prepare = next(command for name, command, _ in self.calls if name == "prepare-flavor")
        self.assertIn("prod", prepare)
        self.assertIn("--android-signing", prepare)
        self.assertIn("--android-identity", prepare)
        build = next(command for name, command, _ in self.calls if name == "flutter-apk")
        self.assertIn("--dart-define=XB_ANDROID_ABI=arm64-v8a", build)
        self.assertIn("--split-debug-info=build/debug-info", build)

    def test_custom_gradle_home_completes_release_without_home_directory(self):
        with mock.patch.object(android.Path, "home", side_effect=RuntimeError("home directory unavailable")) as home:
            self.assertEqual(self.run_fake(), 0)
        home.assert_not_called()
        self.assertEqual(self.counter.read_text(), "18\n")
        self.assertTrue((self.root / "dist/test-0.0.1-android-arm64-v8a.apk").is_file())
        self.assert_restored()

    def test_each_failure_keeps_success_counter_and_restores_temporary_state(self):
        for step in ("native-inputs", "sdk-pub-get", "clean", "pub-get", "prepare-flavor", "sentry-preflight", "flutter-apk", "sentry-symbols"):
            with self.subTest(step=step):
                self.calls.clear()
                self.assertEqual(self.run_fake(step), 1)
                self.assertEqual(self.counter.read_text(), "17\n")
                self.assertFalse((self.root / "dist/test-0.0.1-android-arm64-v8a.apk").exists())
                self.assert_restored()

    def test_explicit_diagnostic_has_separate_output_and_no_counter_advance(self):
        self.assertEqual(self.run_fake(arguments=[*self.arguments, "--audit-only"]), 0)
        self.assertEqual(self.counter.read_text(), "17\n")
        self.assertFalse((self.root / "dist/test-0.0.1-android-arm64-v8a.apk").exists())
        report = json.loads((self.batch / "verification.json").read_text())
        self.assertEqual(report["status"], "verified_diagnostic")
        self.assertTrue(report["artifact"].endswith("-diagnostic.apk"))

    def test_debug_never_runs_sentry_preflight_or_upload_or_advances_counter(self):
        arguments = self.arguments.copy()
        arguments[0] = "debug"
        self.assertEqual(self.run_fake(arguments=arguments), 0)
        self.assertFalse(any(name.startswith("sentry-") for name, *_ in self.calls))
        self.assertEqual(self.counter.read_text(), "17\n")
        self.assert_restored()

    def test_retry_same_batch_preserves_number_and_rejects_changed_source_inputs(self):
        self.assertEqual(self.run_fake("flutter-apk"), 1)
        self.assertEqual(self.run_fake("flutter-apk"), 1)
        changed = self.arguments.copy()
        changed[changed.index("arm64")] = "x64"
        self.assertEqual(self.run_fake(arguments=changed), 1)
        self.assertEqual(self.counter.read_text(), "17\n")

    def test_development_50_and_51_do_not_change_or_follow_ci_counter(self):
        self.assertEqual(self.run_fake(arguments=[*self.arguments, "--build-number", "50"]), 0)
        self.assertEqual(self.counter.read_text(), "50\n")
        self.assert_restored()
        # A later fetch/update of the tracked CI counter does not set the local number.
        self.ci_counter.write_text("100\n")
        self.batch = self.base / "next-batch"
        args = self.arguments.copy()
        args[args.index("--batch-dir") + 1] = str(self.batch)
        self.calls.clear()
        self.assertEqual(self.run_fake(arguments=args), 0)
        self.assertEqual(self.counter.read_text(), "51\n")
        report = json.loads((self.batch / "verification.json").read_text())
        self.assertEqual(report["buildNumber"], 51)
        self.assert_restored(ci_number="100")

    def test_retry_keeps_explicit_number_without_repeating_override(self):
        self.assertEqual(self.run_fake("flutter-apk", arguments=[*self.arguments, "--build-number", "50"]), 1)
        self.assertEqual(self.counter.read_text(), "17\n")
        self.assertEqual(self.run_fake(), 0)
        self.assertEqual(self.counter.read_text(), "50\n")
        self.assert_restored()

    def test_stale_failed_batch_cannot_overwrite_a_later_success(self):
        self.assertEqual(self.run_fake("flutter-apk"), 1)
        android.write_local_build_number(self.root, "brand_a", 50)
        self.calls.clear()
        self.assertEqual(self.run_fake(), 1)
        self.assertFalse(self.calls)
        self.assertEqual(self.counter.read_text(), "50\n")
        self.assert_restored()

    def test_counter_is_read_only_after_acquiring_local_lock(self):
        original = android.read_local_build_number
        def read(root, flavor):
            self.assertTrue((root / "android/.xfl-local-build.lock").is_file())
            return original(root, flavor)
        with mock.patch.object(android, "read_local_build_number", side_effect=read) as reader:
            self.assertEqual(self.run_fake(), 0)
        reader.assert_called_once()
        self.assert_restored()

    def test_active_local_build_lock_is_never_removed_by_second_build(self):
        lock = self.root / "android/.xfl-local-build.lock"
        lock.write_text("another process")
        self.assertEqual(self.run_fake(), 1)
        self.assertEqual(lock.read_text(), "another process")
        self.assertFalse(self.calls)
        self.assertFalse(self.counter.exists())
        self.assertEqual(self.ci_counter.read_text(), "17\n")

    def test_restoration_failure_cannot_promote_or_advance_release(self):
        original = android.temporary_android_configuration
        @contextlib.contextmanager
        def failing_restore(root, gradle_home, **kwargs):
            with original(root, gradle_home, **kwargs):
                yield
            raise OSError("fake restore failure")
        previous = self.root / "dist/test-0.0.1-android-arm64-v8a.apk"
        previous.parent.mkdir()
        previous.write_bytes(b"trusted previous release")
        with mock.patch.object(android, "temporary_android_configuration", failing_restore):
            self.assertEqual(self.run_fake(), 1)
        self.assertEqual(previous.read_bytes(), b"trusted previous release")
        self.assertEqual(self.counter.read_text(), "17\n")
        self.assertFalse((self.batch / "verification.json").exists())

    def test_source_edit_during_build_stops_before_symbols_upload(self):
        self.assertEqual(self.run_fake(change_source_at="flutter-apk"), 1)
        self.assertNotIn("sentry-symbols", [name for name, *_ in self.calls])
        self.assertEqual(self.counter.read_text(), "17\n")
        self.assertFalse((self.batch / "verification.json").exists())
        self.assert_restored()

    def test_head_change_after_build_stops_before_symbols_upload(self):
        self.assertEqual(self.run_fake(change_head_at="flutter-apk"), 1)
        self.assertNotIn("sentry-symbols", [name for name, *_ in self.calls])
        self.assertEqual(self.counter.read_text(), "17\n")
        self.assert_restored()

    def test_wrong_batch_completion_evidence_cannot_promote_release(self):
        self.assertEqual(self.run_fake(invalid_evidence=True), 1)
        self.assertEqual(self.counter.read_text(), "17\n")
        self.assertFalse((self.batch / "verification.json").exists())

    def test_upload_failure_retains_verified_apk_hash_after_future_clean(self):
        self.assertEqual(self.run_fake(failure="sentry-symbols"), 1)
        saved = self.batch / "verified-apk.apk"
        metadata = json.loads((self.batch / "verified-apk.json").read_text())
        self.assertEqual(saved.read_bytes(), b"fake-apk")
        self.assertEqual(metadata["sha256"], hashlib.sha256(saved.read_bytes()).hexdigest())
        self.assertEqual(metadata["stage"], "apk_verified_before_symbols")
        if os.name == "posix":
            self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.batch / "verification.json").exists())
        shutil.rmtree(self.root / "build")
        self.assertTrue(saved.is_file())
        self.assertEqual(self.counter.read_text(), "17\n")

    def test_matching_symbols_are_archived_without_copying_private_defines(self):
        native = self.root / "build/sentry-native/android"
        native.mkdir(parents=True)
        (native / "manifest.json").write_text("{}")
        (native / "test.so.debug").write_bytes(b"fake-companion")
        debug = self.root / "build/debug-info"
        debug.mkdir()
        (debug / "app.android-arm64.symbols").write_bytes(b"fake-dart")
        (self.root / "flavor_defines.json").write_text(json.dumps({"XB_SENTRY_DSN": "private-dsn", "XB_AES_KEY_B64": "fake-private-key"}))
        self.batch.mkdir()
        archive = android.archive_android_symbols(self.root, self.batch, "brand_a")
        self.assertTrue((archive / "build/sentry-native/android/test.so.debug").is_file())
        summary = (archive / "symbol-config.json").read_text()
        self.assertNotIn("private-dsn", summary)
        self.assertNotIn("fake-private-key", summary)
        self.assertIn("enabled", summary)

    def test_absent_temporary_files_are_removed_on_failure(self):
        self.properties.unlink()
        self.keystore.unlink()
        with self.assertRaises(RuntimeError):
            with android.temporary_android_configuration(self.root, self.gradle_home):
                self.properties.write_text("XB_TARGET_ABI=arm64-v8a")
                self.keystore.write_bytes(b"temporary")
                raise RuntimeError("fake failure")
        self.assertFalse(self.properties.exists())
        self.assertFalse(self.keystore.exists())

    def test_pubspec_user_edit_is_kept_while_release_promotion_is_blocked(self):
        previous=self.root/'dist/test-0.0.1-android-arm64-v8a.apk'
        previous.parent.mkdir();previous.write_bytes(b'trusted previous release')
        self.assertEqual(self.run_fake(change_pubspec_at='sentry-symbols'),1)
        self.assertIn('0.9.0+456',(self.root/'pubspec.yaml').read_text())
        self.assertIn('- flavors/brand_a/assets/\n',(self.root/'pubspec.yaml').read_text())
        self.assertEqual(previous.read_bytes(),b'trusted previous release')
        self.assertEqual(self.counter.read_text(),'17\n')

    def test_pubspec_non_asset_edits_survive_success_and_failure_cleanup(self):
        spec=self.root/'pubspec.yaml'
        original=spec.read_bytes()
        for fail in (False,True):
            spec.write_bytes(original)
            try:
                with android.temporary_android_configuration(self.root,self.gradle_home,flavor='brand_a'):
                    spec.write_bytes(original.replace(b'brand_a/assets/',b'brand_a/assets/fallback.bin').replace(b'0.8.93+123',b'0.9.0+456'))
                    if fail:raise RuntimeError('build failed')
            except RuntimeError as error:
                if not fail:raise
                self.assertEqual(str(error),'build failed')
            self.assertEqual(spec.read_bytes(),original.replace(b'0.8.93+123',b'0.9.0+456'))

    def test_pubspec_block_conflict_or_deletion_is_preserved_and_cleanup_still_runs(self):
        spec=self.root/'pubspec.yaml';original=spec.read_bytes()
        for deleted in (False,True):
            spec.write_bytes(original)
            with self.assertRaises(android.ReleaseError):
                with android.temporary_android_configuration(self.root,self.gradle_home,flavor='brand_a'):
                    self.properties.write_text('temporary signing')
                    if deleted:spec.unlink()
                    else:spec.write_text('user replaced the entire file')
            if deleted:self.assertFalse(spec.exists())
            else:self.assertEqual(spec.read_text(),'user replaced the entire file')
            self.assertEqual(self.properties.read_text(),'sdk.dir=/original\nXB_TARGET_ABI=x86_64\n')
            self.assertEqual(list((self.gradle_home/'init.d').iterdir()),[self.existing_init])

    def test_failed_atomic_pubspec_restore_preserves_current_bytes(self):
        spec=self.root/'pubspec.yaml'
        current=spec.read_bytes().replace(b'brand_a/assets/',b'brand_a/assets/fallback.bin').replace(b'0.8.93+123',b'0.9.0+456')
        with self.assertRaises(android.ReleaseError):
            with mock.patch.object(Path,'replace',side_effect=OSError('write failure')):
                with android.temporary_android_configuration(self.root,self.gradle_home,flavor='brand_a'):
                    spec.write_bytes(current)
        self.assertEqual(spec.read_bytes(),current)
        self.assertEqual(list(self.root.glob('.xfl-pubspec-*')),[])
        self.assertEqual(list((self.gradle_home/'init.d').iterdir()),[self.existing_init])

    def test_single_abi_override_preserves_other_properties(self):
        android.set_abi(self.properties, "arm64-v8a")
        self.assertEqual(self.properties.read_text(), "sdk.dir=/original\nXB_TARGET_ABI=arm64-v8a\n")

    def test_aot_comparison_rejects_bad_architecture_or_content(self):
        arm = android.elf_code(minimal_aot(), 183)
        self.assertEqual(arm, {".text": b"code", ".rodata": b"data"})
        self.assertNotEqual(arm, android.elf_code(minimal_aot(text=b"stale"), 183))
        for data in (b"invalid", minimal_aot(machine=62), minimal_aot()[:-1]):
            with self.subTest(length=len(data)), self.assertRaises(android.ReleaseError):
                android.elf_code(data, 183)

    def test_final_apk_checks_original_certificate_aot_and_fallback(self):
        apk = self.root / "test.apk"
        fresh = self.root / "build/app/intermediates/flutter/brand_aRelease/arm64-v8a/app.so"
        fresh.parent.mkdir(parents=True)
        fresh.write_bytes(minimal_aot())
        self.properties.write_text("storePassword=fake\nkeyAlias=fake\n")
        with zipfile.ZipFile(apk, "w") as archive:
            for library in ("libapp.so", "libflutter.so", "libclash.so", "librust_api.so"):
                archive.writestr("lib/arm64-v8a/" + library, minimal_aot())
            archive.writestr("assets/flutter_assets/flavors/brand_a/assets/fallback.bin", b"fake-fallback")
            archive.writestr("classes.dex", "\0".join("com.follow.clash/" + x for x in ["service", "core", "app", "battery", "battery/optimization", "tile"]).encode()+b"\0")
        inputs = {"flavor": "brand_a", "arch": "arm64", "packageName": "com.example.test", "baseVersion": "0.8.93", "buildNumber": 18, "displayName": "Test Brand"}
        certificate = b"original-der-certificate"
        outputs = [b"package: name='com.example.test' versionCode='1000018' versionName='0.8.93'\napplication-label:'Test Brand'\n", resource_dump("com.example.test").encode(), certificate,
                   ("V2 Signer: certificate SHA-256 digest: " + hashlib.sha256(certificate).hexdigest() + '\n' + pem_certificate(certificate)).encode(), b""]
        with mock.patch.object(android, "captured", side_effect=outputs):
            report = android.verify_apk(self.root, apk, inputs, self.base, {})
        self.assertTrue(report["signatureVerified"])
        self.assertTrue(report["aotCodeMatchesFlutterOutput"])
        self.assertTrue(report["crispResourcesVerified"])
        self.assertEqual(report["crispResourceCount"], 1295)
        uncertain = list(outputs)
        bool_line = next(line for line in resource_dump("com.example.test").splitlines() if ':bool/crisp_is_rtl:' in line)
        uncertain[1] += ('\nconfig ar:\n' + bool_line.replace('t=0x12 d=0x00000000', 't=0x01 d=0x00000000')).encode()
        with mock.patch.object(android, "captured", side_effect=uncertain), self.assertRaisesRegex(android.ReleaseError, 'INCONCLUSIVE'):
            android.verify_apk(self.root, apk, inputs, self.base, {})

        wrong = list(outputs)
        wrong[3] = pem_certificate(b'wrong-signing-certificate').encode()
        with mock.patch.object(android, "captured", side_effect=wrong), self.assertRaisesRegex(android.ReleaseError, 'original brand keystore'):
            android.verify_apk(self.root, apk, inputs, self.base, {})
        legacy = self.root / "build/app/intermediates/flutter/brand_aRelease/jniLibs/arm64-v8a/libapp.so"
        legacy.parent.mkdir(parents=True)
        fresh.rename(legacy)
        with mock.patch.object(android, "captured", side_effect=outputs), self.assertRaisesRegex(android.ReleaseError, 'compiler output is missing'):
            android.verify_apk(self.root, apk, inputs, self.base, {})
        legacy.rename(fresh)
        fresh.write_bytes(minimal_aot(text=b"wrong"))
        with mock.patch.object(android, "captured", side_effect=outputs), self.assertRaises(android.ReleaseError):
            android.verify_apk(self.root, apk, inputs, self.base, {})

    def run_stub_processes(self, fail_symbols=False):
        (self.root / "fixture-crisp-resources.txt").write_text(resource_dump("com.example.test"))
        native = self.root / "tool/prepare_native_build.py"
        native.parent.mkdir(parents=True, exist_ok=True)
        native.write_text("# Fixture: no network or toolchain installation\n")
        """Run the real coordinator against executable stand-ins, never toolchains."""
        binary_dir = self.base / "fake-bin"
        binary_dir.mkdir()
        sdk_tools = self.base / "android-sdk/build-tools/35.0.0"
        sdk_tools.mkdir(parents=True)
        script = "#!" + sys.executable + "\n" + '''
import base64, hashlib, json, os
from pathlib import Path
import shutil, sys, zipfile
root = Path(os.environ['FAKE_RELEASE_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'stub-commands.jsonl').open('a') as log:
    log.write(json.dumps([name, args]) + '\\n')
if name == 'git':
    if args[0] == 'rev-parse':
        print('a' * 40)
    else:
        current = Path.cwd()
        files = ['pubspec.yaml','pubspec.lock','lib/source.dart'] if current == root else ['pubspec.lock','lib/source.dart'] if current.name == 'Xboard_sdk' else ['core.go']
        sys.stdout.buffer.write(('\\0'.join(files) + '\\0').encode())
elif name == 'dart':
    (root / 'flavor_defines.json').write_text(json.dumps({'XB_FLAVOR_ID':'brand_a','XB_DEBUG':'false','XB_SENTRY_DSN':'configured'}))
    (root / 'android/local.properties').write_text('sdk.dir=/fake\\nstorePassword=fake\\nkeyAlias=fake\\nXB_TARGET_ABI=arm64-v8a\\n')
    (root / 'android/app/keystore.jks').write_bytes(b'selected-brand')
elif name == 'flutter' and args == ['clean']:
    shutil.rmtree(root / 'build', ignore_errors=True)
elif name == 'flutter' and args[:2] == ['build', 'apk']:
    data = bytes.fromhex(os.environ['FAKE_AOT_HEX'])
    fresh = root / 'build/app/intermediates/flutter/brand_aRelease/arm64-v8a/app.so'
    fresh.parent.mkdir(parents=True)
    fresh.write_bytes(data)
    apk = root / 'build/app/outputs/flutter-apk/app-brand_a-release.apk'
    apk.parent.mkdir(parents=True)
    with zipfile.ZipFile(apk, 'w') as archive:
        for library in ['libapp.so', 'libflutter.so', 'libclash.so', 'librust_api.so']:
            archive.writestr('lib/arm64-v8a/' + library, data)
        archive.writestr('assets/flutter_assets/flavors/brand_a/assets/fallback.bin', b'fake-fallback')
        archive.writestr('classes.dex', '\\0'.join('com.follow.clash/' + x for x in ['service', 'core', 'app', 'battery', 'battery/optimization', 'tile']).encode()+b'\\0')
elif name == 'keytool':
    sys.stdout.buffer.write(b'original-der-certificate')
elif name == 'aapt' and args[1] == 'resources':
    print((root / 'fixture-crisp-resources.txt').read_text())
elif name == 'aapt':
    print("package: name='com.example.test' versionCode='1000018' versionName='0.8.93'")
    print("application-label:'Test Brand'")
elif name == 'apksigner':
    assert '--print-certs-pem' in args
    print('Signer #1 certificate SHA-256 digest: ' + hashlib.sha256(b'original-der-certificate').hexdigest())
    print('-----BEGIN CERTIFICATE-----')
    print(base64.b64encode(b'original-der-certificate').decode())
    print('-----END CERTIFICATE-----')
'''
        implementation = binary_dir / "fake-tool"
        implementation.write_text(script)
        implementation.chmod(0o700)
        for name in ("flutter", "dart", "git", "bash", "keytool"):
            (binary_dir / name).symlink_to(implementation)
        for name in ("aapt", "apksigner", "zipalign"):
            (sdk_tools / name).symlink_to(implementation)
        (self.root / "tool").mkdir(exist_ok=True)
        (self.root / "tool/postbuild_sentry_symbols.py").write_text('''
import json, os
from pathlib import Path
import sys
args = sys.argv[1:]
if '--package' in args and os.environ.get('FAKE_FAIL_SYMBOLS'):
    raise SystemExit(9)
if '--preflight' not in args:
    Path(args[args.index('--evidence')+1]).write_text(json.dumps({'status':'uploaded_and_processed', 'platform':'android',
        'flavor':'brand_a','product_version':'0.0.1','build_number':'18','source_revision':'a'*40}))
''')
        environment = {"PATH": str(binary_dir) + os.pathsep + os.defpath, "HOME": str(self.base),
                       "ANDROID_HOME": str(self.base / "android-sdk"), "ANDROID_NDK": "fake-ndk",
                       "GRADLE_USER_HOME": str(self.gradle_home), "FAKE_RELEASE_ROOT": str(self.root),
                       "FAKE_AOT_HEX": minimal_aot().hex()}
        if fail_symbols:
            environment["FAKE_FAIL_SYMBOLS"] = "1"
        return subprocess.run([sys.executable, str(Path(android.__file__).resolve()), *self.arguments],
                              env=environment, capture_output=True, text=True, timeout=20)

    @unittest.skipIf(os.name == "nt", "Executable POSIX shebang/symlink fixtures require a Unix host; Windows runs mocked coordinator cases")
    def test_real_coordinator_with_stub_processes_completes_verified_release(self):
        result = self.run_stub_processes()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.counter.read_text(), "18\n")
        report = json.loads((self.batch / "verification.json").read_text())
        self.assertTrue(report["sentrySymbolsUploaded"])
        self.assertTrue(report["aotCodeMatchesFlutterOutput"])
        self.assertTrue(report["crispResourcesVerified"])
        self.assertEqual(report["crispResourceCount"], 1295)

        self.assert_restored()

    @unittest.skipIf(os.name == "nt", "Executable POSIX shebang/symlink fixtures require a Unix host; Windows runs mocked coordinator cases")
    def test_real_coordinator_stub_upload_failure_keeps_previous_release(self):
        result = self.run_stub_processes(fail_symbols=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.counter.read_text(), "17\n")
        self.assertFalse((self.batch / "verification.json").exists())
        self.assertFalse((self.root / "dist/test-0.0.1-android-arm64-v8a.apk").exists())
        self.assertTrue((self.batch / "verified-apk.apk").is_file())
        self.assertTrue((self.batch / "verified-apk.json").is_file())
        self.assert_restored()


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Desktop credential isolation fixture executes a POSIX shell block")
class DesktopCredentialTests(unittest.TestCase):
    def test_real_shell_block_withholds_credentials_from_build_tools(self):
        source = (Path(__file__).resolve().parents[2] / "scripts/package_desktop_local.sh").read_text()
        begin = source.index('XFL_LOCAL_SENTRY_UPLOAD_TOKEN="${SENTRY_AUTH_TOKEN:-}"')
        end = source.index("# ───────── 参数解析", begin)
        actual_block = source[begin:end]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            binary_dir = root / "bin"
            binary_dir.mkdir()
            observer = binary_dir / "observe"
            observer.write_text("#!" + sys.executable + "\nimport json,os,sys\n"
                                "with open(os.environ['FIXTURE_OBSERVATIONS'],'a') as stream:\n"
                                "    stream.write(json.dumps({'tool':os.path.basename(sys.argv[0]),'upload':bool(os.environ.get('SENTRY_AUTH_TOKEN')),'maintenance':bool(os.environ.get('SENTRY_MAINTENANCE_TOKEN')),'private_exported':'XFL_LOCAL_SENTRY_UPLOAD_TOKEN' in os.environ,'args':sys.argv[1:]})+'\\n')\n")
            observer.chmod(0o700)
            for name in ("flutter", "dart", "python3"):
                (binary_dir / name).symlink_to(observer)
            observations = root / "observations.jsonl"
            script = actual_block + "\nflutter fixture\ndart fixture\nrun_sentry_postbuild --preflight\nrun_sentry_postbuild --platform linux\n"
            result = subprocess.run([shutil.which("bash"), "-c", script], capture_output=True, text=True,
                                    env={"PATH": str(binary_dir) + os.pathsep + os.defpath,
                                         "FIXTURE_OBSERVATIONS": str(observations),
                                         "SENTRY_AUTH_TOKEN": "fixture-only-upload", "SENTRY_MAINTENANCE_TOKEN": "fixture-only-maintenance",
                                         "XFL_LOCAL_SENTRY_UPLOAD_TOKEN": "previously-exported-must-be-private"})
            self.assertEqual(result.returncode, 0, result.stderr)
            seen = [json.loads(line) for line in observations.read_text().splitlines()]
            self.assertEqual([item["tool"] for item in seen], ["flutter", "dart", "python3", "python3"])
            self.assertEqual([item["upload"] for item in seen], [False, False, True, True])
            self.assertFalse(any(item["maintenance"] or item["private_exported"] for item in seen))
            self.assertTrue(all(item["args"][0] == "tool/postbuild_sentry_symbols.py" for item in seen[2:]))
            self.assertNotIn("fixture-only-upload", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
