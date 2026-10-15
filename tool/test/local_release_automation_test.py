#!/usr/bin/env python3
"""Exercise release sequencing and failure recovery using temporary fake projects.

No Flutter, Go core build, network upload, signing or real APK is invoked.
"""

from __future__ import annotations

import contextlib
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
import build_android_local as android
import postbuild_sentry_symbols as postbuild


class PostbuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "flavors").mkdir()
        (self.root / "flavors/sentry-cli.token").write_text("fake-upload-token\n")
        self.defines = self.root / "flavor_defines.json"
        self.defines.write_text(json.dumps({"XB_FLAVOR_ID": "brand_a", "XB_DEBUG": "false", "XB_SENTRY_DSN": "https://example.invalid/1"}))
        self.arguments = ["--project-root", str(self.root), "--platform", "android", "--flavor", "brand_a"]

    def test_preflight_requires_no_symbols_and_does_not_start_subcommands(self):
        with mock.patch.object(postbuild, "resolve_cli", return_value="fake-cli"), mock.patch.object(postbuild, "run_checked") as run:
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
            with self.subTest(platform=platform), mock.patch.object(postbuild, "resolve_cli", return_value="fixed-cli"), mock.patch.object(postbuild, "run_checked", side_effect=write_evidence) as run:
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

    def test_prepare_failure_prevents_upload(self):
        with mock.patch.object(postbuild, "resolve_cli", return_value="fake-cli"), mock.patch.object(postbuild, "run_checked", side_effect=postbuild.ReleaseError("prepared failed")) as run:
            self.assertEqual(postbuild.main([*self.arguments, "--package", "final.apk"]), 1)
        self.assertEqual(run.call_count, 1)

    def test_cli_version_is_pinned(self):
        with mock.patch.object(postbuild.shutil, "which", return_value="fake-cli"), mock.patch.object(postbuild.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="sentry-cli 2.99.0\n")):
            with self.assertRaises(postbuild.ReleaseError):
                postbuild.resolve_cli(None, {})

    def test_stale_completion_report_cannot_replace_upload_confirmation(self):
        evidence = self.root / "build/sentry-symbols-evidence.json"
        evidence.parent.mkdir()
        evidence.write_text(json.dumps({"status": "uploaded_and_processed", "platform": "android", "flavor": "brand_a"}))
        with mock.patch.object(postbuild, "resolve_cli", return_value="fixed-cli"), mock.patch.object(postbuild, "run_checked"):
            self.assertEqual(postbuild.main([*self.arguments, "--package", "final.apk"]), 1)
        self.assertFalse(evidence.exists())

    def test_reuse_prepared_audits_archive_without_regenerating_it(self):
        def complete(command, **_kwargs):
            evidence = self.root / "build/sentry-symbols-evidence.json"
            evidence.parent.mkdir(exist_ok=True)
            evidence.write_text(json.dumps({"status": "audited", "platform": "android", "flavor": "brand_a"}))
        with mock.patch.object(postbuild, "resolve_cli", return_value="fake-cli"), mock.patch.object(postbuild, "run_checked", side_effect=complete) as run:
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
        self.base = Path(self.temp.name)
        self.root = self.base / "client"
        self.sdk = self.base / "Xboard_sdk"
        for directory in (self.root / "android/app", self.root / "flavors/brand_a/assets", self.root / "scripts", self.root / "lib", self.root / "core/Clash.Meta", self.sdk / "lib"):
            directory.mkdir(parents=True)
        (self.root / "pubspec.yaml").write_text("version: 0.8.93+123\n")
        (self.root / "pubspec.lock").write_text("client lock")
        (self.sdk / "pubspec.lock").write_text("SDK lock")
        (self.root / "lib/source.dart").write_text("original client source")
        (self.sdk / "lib/source.dart").write_text("original SDK source")
        (self.root / "core/Clash.Meta/core.go").write_text("original core source")
        (self.root / "flavors/brand_a/flavor.yaml").write_text("versionName: '0.0.1'\nappId: com.example.test\nappName: Test Brand\nupdatePackageName: test\n")
        (self.root / "flavors/brand_a/assets/fallback.bin").write_bytes(b"fake-fallback")
        self.counter = self.root / "scripts/build_number.brand_a.txt"
        self.counter.write_text("17\n")
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

    def run_fake(self, failure=None, arguments=None, change_source_at=None, change_head_at=None, invalid_evidence=False):
        owner = self
        head = "a" * 40
        def run(builder, command, name, cwd=None):
            nonlocal head
            owner.calls.append((name, command, cwd))
            if name == change_head_at:
                head = "b" * 40
            if name == change_source_at:
                (owner.root / "lib/source.dart").write_text("changed during build")
            if name == failure:
                raise android.ReleaseError("fake failure at " + name)
            if name == "prepare-flavor":
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
                            "platform": "android", "flavor": "brand_a", "product_version": "0.0.1", "build_number": "18", "source_revision": "a" * 40}
                if invalid_evidence:
                    evidence["build_number"] = "17"
                (owner.batch / "sentry-symbols-evidence.json").write_text(json.dumps(evidence))
        def git_output(command, cwd=None, text=False):
            if command[1] == "rev-parse":
                return head
            repository = Path(cwd)
            names = ("pubspec.yaml\0pubspec.lock\0lib/source.dart\0" if repository == owner.root else "pubspec.lock\0lib/source.dart\0" if repository == owner.sdk else "core.go\0")
            return names.encode()
        with mock.patch.dict(os.environ, {"ANDROID_HOME": str(self.base / "android-sdk"), "ANDROID_NDK": "fake-ndk", "GRADLE_USER_HOME": str(self.gradle_home)}, clear=True), mock.patch.object(android.shutil, "which", return_value="fake-tool"), mock.patch.object(android, "android_tools", return_value=self.base), mock.patch.object(android.subprocess, "check_output", side_effect=git_output), mock.patch.object(android.LocalBuild, "run", run), mock.patch.object(android, "verify_apk", return_value={"signatureVerified": True}), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return android.main(arguments or self.arguments)

    def assert_restored(self):
        self.assertEqual(self.properties.read_text(), "sdk.dir=/original\nXB_TARGET_ABI=x86_64\n")
        self.assertEqual(self.keystore.read_bytes(), b"original-keystore")
        self.assertEqual(list((self.gradle_home / "init.d").iterdir()), [self.existing_init])
        self.assertFalse((self.root / "android/.xfl-local-build.lock").exists())

    def test_release_finishes_only_after_verification_and_symbols(self):
        self.assertEqual(self.run_fake(), 0)
        self.assertEqual([name for name, *_ in self.calls], ["sdk-pub-get", "clean", "pub-get", "prepare-flavor", "sentry-preflight", "go-core-build", "flutter-apk", "sentry-symbols"])
        self.assertEqual(self.counter.read_text(), "18\n")
        self.assertTrue((self.root / "dist/test-0.0.1-android-arm64-v8a.apk").is_file())
        self.assert_restored()
        prepare = next(command for name, command, _ in self.calls if name == "prepare-flavor")
        self.assertIn("prod", prepare)
        self.assertIn("--android-signing", prepare)
        build = next(command for name, command, _ in self.calls if name == "flutter-apk")
        self.assertIn("--dart-define=XB_ANDROID_ABI=arm64-v8a", build)
        self.assertIn("--split-debug-info=build/debug-info", build)

    def test_each_failure_keeps_success_counter_and_restores_temporary_state(self):
        for step in ("sdk-pub-get", "clean", "pub-get", "prepare-flavor", "sentry-preflight", "go-core-build", "flutter-apk", "sentry-symbols"):
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

    def test_active_local_build_lock_is_never_removed_by_second_build(self):
        lock = self.root / "android/.xfl-local-build.lock"
        lock.write_text("another process")
        self.assertEqual(self.run_fake(), 1)
        self.assertEqual(lock.read_text(), "another process")
        self.assertFalse(self.calls)

    def test_restoration_failure_cannot_promote_or_advance_release(self):
        original = android.temporary_android_configuration
        @contextlib.contextmanager
        def failing_restore(root, gradle_home):
            with original(root, gradle_home):
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
        fresh = self.root / "build/app/intermediates/flutter/brand_aRelease/jniLibs/arm64-v8a/libapp.so"
        fresh.parent.mkdir(parents=True)
        fresh.write_bytes(minimal_aot())
        self.properties.write_text("storePassword=fake\nkeyAlias=fake\n")
        with zipfile.ZipFile(apk, "w") as archive:
            for library in ("libapp.so", "libflutter.so", "libclash.so", "libcore.so"):
                archive.writestr("lib/arm64-v8a/" + library, minimal_aot())
            archive.writestr("assets/flutter_assets/flavors/brand_a/assets/fallback.bin", b"fake-fallback")
        inputs = {"flavor": "brand_a", "arch": "arm64", "packageName": "com.example.test", "baseVersion": "0.8.93", "buildNumber": 18, "displayName": "Test Brand"}
        certificate = b"original-der-certificate"
        outputs = [b"package: name='com.example.test' versionCode='18' versionName='0.8.93'\napplication-label:'Test Brand'\n", certificate,
                   ("Signer #1 certificate SHA-256 digest: " + hashlib.sha256(certificate).hexdigest()).encode(), b""]
        with mock.patch.object(android, "captured", side_effect=outputs):
            report = android.verify_apk(self.root, apk, inputs, self.base, {})
        self.assertTrue(report["signatureVerified"])
        self.assertTrue(report["aotCodeMatchesFlutterOutput"])
        fresh.write_bytes(minimal_aot(text=b"wrong"))
        with mock.patch.object(android, "captured", side_effect=outputs), self.assertRaises(android.ReleaseError):
            android.verify_apk(self.root, apk, inputs, self.base, {})

    def run_stub_processes(self, fail_symbols=False):
        """Run the real coordinator against executable stand-ins, never toolchains."""
        binary_dir = self.base / "fake-bin"
        binary_dir.mkdir()
        sdk_tools = self.base / "android-sdk/build-tools/35.0.0"
        sdk_tools.mkdir(parents=True)
        script = "#!" + sys.executable + "\n" + '''
import hashlib, json, os
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
    fresh = root / 'build/app/intermediates/flutter/brand_aRelease/jniLibs/arm64-v8a/libapp.so'
    fresh.parent.mkdir(parents=True)
    fresh.write_bytes(data)
    apk = root / 'build/app/outputs/flutter-apk/app-brand_a-release.apk'
    apk.parent.mkdir(parents=True)
    with zipfile.ZipFile(apk, 'w') as archive:
        for library in ['libapp.so', 'libflutter.so', 'libclash.so', 'libcore.so']:
            archive.writestr('lib/arm64-v8a/' + library, data)
        archive.writestr('assets/flutter_assets/flavors/brand_a/assets/fallback.bin', b'fake-fallback')
elif name == 'keytool':
    sys.stdout.buffer.write(b'original-der-certificate')
elif name == 'aapt':
    print("package: name='com.example.test' versionCode='18' versionName='0.8.93'")
    print("application-label:'Test Brand'")
elif name == 'apksigner':
    print('Signer #1 certificate SHA-256 digest: ' + hashlib.sha256(b'original-der-certificate').hexdigest())
'''
        implementation = binary_dir / "fake-tool"
        implementation.write_text(script)
        implementation.chmod(0o700)
        for name in ("flutter", "dart", "git", "bash", "keytool"):
            (binary_dir / name).symlink_to(implementation)
        for name in ("aapt", "apksigner", "zipalign"):
            (sdk_tools / name).symlink_to(implementation)
        (self.root / "tool").mkdir()
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
            root = Path(temporary)
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
