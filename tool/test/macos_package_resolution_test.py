#!/usr/bin/env python3
"""Offline subprocess fixtures; never invokes Xcode or resolves packages."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import resolve_macos_packages as diagnostic


class PackageResolutionTests(unittest.TestCase):
    def test_explicit_project_changes_only_the_resolve_container(self):
        root = Path("/fixture/project")
        implicit, listing = diagnostic.commands(root, arm=False, xcrun="/usr/bin/xcrun")
        explicit, same_listing = diagnostic.commands(root, arm=False, xcrun="/usr/bin/xcrun", explicit_project=True)
        self.assertEqual(explicit, implicit + ["-project", "Runner.xcodeproj"])
        self.assertEqual(listing, same_listing)

    def test_commands_match_flutter_cache_and_keep_validation_defaults(self):
        root = Path("/fixture/project")
        resolve, listing = diagnostic.commands(root, arm=True, xcrun="/usr/bin/xcrun")
        self.assertEqual(resolve, ["/usr/bin/arch", "-arm64e", "/usr/bin/xcrun", "xcodebuild",
            "-clonedSourcePackagesDirPath", "/fixture/project/build/macos/SourcePackages", "-resolvePackageDependencies"])
        self.assertEqual(listing[-4:], ["-skipPackageUpdates", "-list", "-project", "Runner.xcodeproj"])
        self.assertNotIn("-skipPackagePluginValidation", listing)
        self.assertNotIn("-skipPackageSignatureValidation", listing)

    def test_child_environment_removes_credentials_and_encoded_defines(self):
        environment = diagnostic.child_environment({"PATH": "/tools", "DART_DEFINES": "private",
            "XB_AES_KEY": "private", "SENTRY_AUTH_TOKEN": "private", "SENTRY_MAINTENANCE_TOKEN": "private",
            "SENTRY_DSN": "private", "GH_TOKEN": "private", "GIT_TERMINAL_PROMPT": "1"})
        self.assertEqual(environment, {"PATH": "/tools", "GIT_TERMINAL_PROMPT": "0"})

    def test_progress_never_emits_arbitrary_values_or_url_credentials(self):
        for line in ("DART_DEFINES=private-value", "token=private-value", "arbitrary /private/source/path"):
            self.assertIsNone(diagnostic.safe_progress(line))
        line = "Fetching https://secret-user:private-token@github.com/getsentry/sentry-cocoa.git?token=private-query"
        self.assertEqual(diagnostic.safe_progress(line), "fetching_package github.com/getsentry/sentry-cocoa")
        self.assertEqual(diagnostic.safe_progress("error: https://private.invalid/repo?password=private-query"),
                         "dependency_error [redacted-url]")
        self.assertEqual(diagnostic.safe_progress("Fetching https://private-token@github.com/simolus3/CSQLite.git?token=private-query"),
                         "fetching_package github.com/simolus3/CSQLite")

    def test_cleanup_matches_only_same_user_exact_flutter_prefetch_and_its_children(self):
        cache = Path("/fixture/build/macos/SourcePackages")
        rows = "\n".join((
            f"100 1 501 /Xcode/usr/bin/xcodebuild -clonedSourcePackagesDirPath {cache} -resolvePackageDependencies",
            "101 100 501 /usr/bin/git fetch https://private.invalid/repo",
            f"102 1 502 /Xcode/usr/bin/xcodebuild -clonedSourcePackagesDirPath {cache} -resolvePackageDependencies",
            "103 1 501 /Xcode/usr/bin/xcodebuild -clonedSourcePackagesDirPath /other/cache -resolvePackageDependencies",
            f"104 1 501 /Xcode/usr/bin/xcodebuild -clonedSourcePackagesDirPath {cache} -resolvePackageDependencies -project Other.xcodeproj"))
        self.assertEqual(diagnostic.stale_prefetches(rows, cache, 501), ([100], [100, 101]))

    @unittest.skipIf(os.name == "nt", "Process-group fixtures require POSIX")
    def test_streaming_child_output_is_safe_and_nonzero_exit_is_reported(self):
        messages = []
        with tempfile.TemporaryDirectory() as temporary:
            result = diagnostic.run_stage("resolve", [sys.executable, "-c",
                "print('DART_DEFINES=private-value');print('error: token=private-token');raise SystemExit(7)"],
                Path(temporary).resolve(), diagnostic.child_environment(dict(os.environ)), 5,
                emit=lambda message, **kwargs: messages.append(message))
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(result["output_lines"], 2)
        self.assertNotIn("private", json.dumps(messages) + json.dumps(result))

    @unittest.skipIf(os.name == "nt", "Process-group fixtures require POSIX")
    def test_silent_timeout_terminates_own_group_and_emits_heartbeat(self):
        messages = []
        with tempfile.TemporaryDirectory() as temporary:
            result = diagnostic.run_stage("resolve", [sys.executable, "-c", "import time;time.sleep(60)"],
                Path(temporary).resolve(), diagnostic.child_environment(dict(os.environ)), .35,
                heartbeat=.1, emit=lambda message, **kwargs: messages.append(message))
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["reason"], "phase_timeout")
        self.assertGreater(result["heartbeats"], 0)
        self.assertLess(result["elapsed_seconds"], 5)

    def test_resolve_failure_prevents_list_and_report_contains_no_raw_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            project = root / "macos/Runner.xcodeproj/project.pbxproj"
            project.parent.mkdir(parents=True)
            project.write_text("fixture")
            output = root / "safe.json"
            with mock.patch.object(diagnostic.sys, "platform", "darwin"), \
                 mock.patch.object(diagnostic.shutil, "which", return_value="/usr/bin/xcrun"), \
                 mock.patch.object(diagnostic, "preflight_diagnostics", return_value=[{"phase": "generated_package_dump", "status": "failed"}]), \
                 mock.patch.object(diagnostic, "cache_snapshot", return_value={"project_artifacts": {"status": "missing"}}), \
                 mock.patch.object(diagnostic, "run_stage", return_value={"phase": "resolve", "status": "failed",
                    "exit_code": 1, "timed_out": False}) as stage, mock.patch("builtins.print"):
                result = diagnostic.main(["--project-root", str(root), "--report", str(output)])
            self.assertEqual(result, 1)
            stage.assert_called_once()
            report = json.loads(output.read_text())
            self.assertEqual(report["reason"], "resolve_phase_failed")
            self.assertFalse(report["build_performed"])
            self.assertEqual(report["diagnostics"][0]["status"], "failed")
            self.assertEqual([item["point"] for item in report["cache_snapshots"]], ["before_resolve", "after_resolve"])
            self.assertEqual(report["scm_provider"], "default")

    def test_diagnostic_metadata_keeps_only_versions_fixed_package_counts_and_ref_shas(self):
        self.assertEqual(diagnostic.diagnostic_metadata("xcode_version", b"Xcode 26.1\nBuild version SECRET\n"),
                         {"metadata_status": "complete", "version": "26.1"})
        self.assertEqual(diagnostic.diagnostic_metadata("swift_version", b"Apple Swift version 6.2.1 (private compiler path)\n"),
                         {"metadata_status": "complete", "version": "6.2.1"})
        manifest = {"name": diagnostic.GENERATED_PACKAGE, "targets": [{"path": "/private/source"}],
                    "dependencies": [{"url": "https://private-token@private.invalid"}], "products": [],
                    "toolsVersion": {"_version": "6.0.0"}, "secret": "private-token"}
        safe = diagnostic.diagnostic_metadata("generated_package_dump", json.dumps(manifest).encode())
        self.assertEqual(safe["target_count"], 1)
        self.assertEqual(safe["dependency_count"], 1)
        self.assertNotIn("private", json.dumps(safe))
        raw = ("a" * 40 + "\tHEAD\nprivate-token\trefs/private\n").encode()
        self.assertEqual(diagnostic.diagnostic_metadata("sentry_cocoa_remote", raw),
                         {"metadata_status": "complete", "head_sha": "a" * 40})

    def test_process_snapshot_is_same_user_tree_with_only_known_names_and_numeric_usage(self):
        raw = "\n".join(("200 1 501 0.0 100 /Xcode/bin/xcodebuild",
            "201 200 501 2.5 200 /usr/bin/git", "202 201 501 0.1 50 /private/secret-process",
            "203 200 502 1.0 99 /usr/bin/swift", "204 1 501 50.0 999 /usr/bin/git"))
        summary = diagnostic.safe_process_tree(raw, 200, 501)
        self.assertEqual([item["pid"] for item in summary["processes"]], [200, 201, 202])
        self.assertEqual([item["name"] for item in summary["processes"]], ["xcodebuild", "git", "other"])
        self.assertEqual(summary["processes"][1]["cpu_percent"], 2.5)
        self.assertNotIn("private", json.dumps(summary))
        self.assertNotIn("secret", json.dumps(summary))

    def test_preflight_failures_do_not_skip_other_diagnostics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            package = root / "macos/Flutter/ephemeral/Packages" / diagnostic.GENERATED_PACKAGE
            package.mkdir(parents=True)
            (package / "Package.swift").write_text("fixture")
            with mock.patch.object(diagnostic, "run_stage", return_value={"status": "failed", "exit_code": 1}) as run, \
                 mock.patch("builtins.print"):
                summaries = diagnostic.preflight_diagnostics(root, ["xcrun"], {"GIT_TERMINAL_PROMPT": "0"})
            self.assertEqual(len(summaries), 6)
            self.assertEqual(run.call_count, 6)
            self.assertEqual([call.args[4] for call in run.call_args_list], [30, 30, 60, 30, 30, 30])
            self.assertIn("ls-remote", run.call_args_list[-1].args[1])
            self.assertEqual(run.call_args_list[-1].args[1][-2:], ["https://github.com/simolus3/CSQLite.git", "HEAD"])
            self.assertEqual(summaries[-1]["required_revision"], "1ee46d19a4f451a7aa64ffc64fc99b4748131e62")
            self.assertNotIn("head_matches_required_revision", summaries[-1])

    @unittest.skipIf(os.name == "nt", "Process-group fixtures require POSIX")
    def test_timeout_saves_scoped_process_snapshot_without_raw_process_text(self):
        messages = []
        def observe(pid, environment):
            return diagnostic.safe_process_tree(f"{pid} 1 501 0.0 50 /Xcode/bin/xcodebuild", pid, 501)
        with tempfile.TemporaryDirectory() as temporary:
            result = diagnostic.run_stage("resolve", [sys.executable, "-c", "import time;time.sleep(60)"],
                Path(temporary).resolve(), {}, .15, observer=observe,
                emit=lambda message, **kwargs: messages.append(message))
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["process_snapshots"][0]["process_count"], 1)
        self.assertNotIn("/Xcode", json.dumps(result) + json.dumps(messages))

    def test_sample_classification_keeps_only_fixed_counts_and_branch_scoped_hints(self):
        same_branch = b'''Call graph:
  3 Thread_999 private-thread-name
    + 3 SecItemCopyMatching (in Security) + 99 /private/source
    + ! 3 semaphore_wait_trap (in libsystem_kernel.dylib) + 12 private-token
'''
        summary = diagnostic.classify_sample(same_branch)
        self.assertTrue(summary["wait_hints"]["security_wait"])
        self.assertFalse(summary["root_cause_established"])
        self.assertNotIn("private", json.dumps(summary))
        # A sibling branch or another thread's wait must not imply a Security wait.
        for separate in (same_branch.replace(b"+ ! 3 semaphore", b"+ 3 semaphore"),
                         same_branch.replace(b"    + ! 3 semaphore", b"  3 Thread_888 other-thread\n    + 3 semaphore")):
            self.assertFalse(diagnostic.classify_sample(separate)["wait_hints"]["security_wait"])
        unknown = diagnostic.classify_sample(b"token=private-token /private/source/path\n")
        self.assertEqual(unknown["classification_status"], "unknown")
        self.assertNotIn("private", json.dumps(unknown))

    def test_sample_refuses_unknown_uid_and_never_invokes_sampler(self):
        process = mock.Mock(pid=123)
        process.poll.return_value = None
        with mock.patch.object(diagnostic.sys, "platform", "darwin"), \
             mock.patch.object(diagnostic.os, "getuid", return_value=501, create=True), \
             mock.patch.object(diagnostic.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="502\n")), \
             mock.patch.object(diagnostic, "bounded_sample_output") as capture:
            result = diagnostic.timeout_sample(process, {})
        self.assertEqual(result["reason"], "sample_target_uid_unconfirmed")
        capture.assert_not_called()

    def test_sample_command_is_fixed_stdout_only_and_report_excludes_raw_stack(self):
        process = mock.Mock(pid=123)
        process.poll.return_value = None
        raw = b"private-token /private/path\n    + 1 flock (in libsystem_kernel.dylib) + 1\n"
        with mock.patch.object(diagnostic.sys, "platform", "darwin"), \
             mock.patch.object(diagnostic.os, "getuid", return_value=501, create=True), \
             mock.patch.object(diagnostic.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="501\n")), \
             mock.patch.object(diagnostic, "bounded_sample_output", return_value=({"status": "complete", "raw_stack_saved": False}, raw)) as capture:
            result = diagnostic.timeout_sample(process, {"GIT_TERMINAL_PROMPT": "0"})
        self.assertEqual(capture.call_args.args[0], ["/usr/bin/sample", "123", "1", "10", "-file", "/dev/stdout"])
        self.assertTrue(result["same_uid_confirmed"])
        self.assertEqual(result["frame_counts"]["file_lock_frames"], 1)
        self.assertNotIn("private", json.dumps(result))

    @unittest.skipIf(os.name == "nt", "Process-group fixtures require POSIX")
    def test_sample_output_is_bounded_without_raw_files_or_console_output(self):
        with mock.patch("builtins.print") as printed:
            summary, raw = diagnostic.bounded_sample_output([sys.executable, "-c",
                "import sys;sys.stdout.write('private-token' * 20000);sys.stdout.flush()"], {})
        self.assertTrue(summary["output_capped"])
        self.assertLessEqual(len(raw), diagnostic.MAX_SAMPLE_BYTES)
        self.assertFalse(summary["raw_stack_saved"])
        printed.assert_not_called()

    @unittest.skipIf(os.name == "nt", "Process-group fixtures require POSIX")
    def test_sample_failure_preserves_resolver_timeout_without_exception_text(self):
        messages = []
        with tempfile.TemporaryDirectory() as temporary:
            result = diagnostic.run_stage("resolve", [sys.executable, "-c", "import time;time.sleep(60)"],
                Path(temporary).resolve(), {}, .1,
                sampler=mock.Mock(side_effect=RuntimeError("private-token /private/path")),
                emit=lambda message, **kwargs: messages.append(message))
        self.assertEqual(result["status"], "timed_out")
        self.assertEqual(result["reason"], "phase_timeout")
        self.assertEqual(result["timeout_sample"]["reason"], "sample_unavailable")
        self.assertNotIn("private", json.dumps(result) + json.dumps(messages))

    def test_system_scm_is_only_an_explicit_optional_argument_pair(self):
        default = diagnostic.commands(Path("/fixture"), arm=False, xcrun="xcrun")
        system = diagnostic.commands(Path("/fixture"), arm=False, xcrun="xcrun", scm_provider="system")
        for original, modified in zip(default, system):
            index = modified.index("-scmProvider")
            self.assertEqual(modified[index:index + 2], ["-scmProvider", "system"])
            self.assertEqual(modified[:index] + modified[index + 2:], original)

    def test_partial_sample_keeps_positive_complete_line_prefix_only(self):
        raw = b'''Call graph:
  3 Thread_999 private-name
    + 3 SecItemCopyMatching (in Security) + 99
    + ! 3 semaphore_wait_trap (in libsystem_kernel.dylib) + 12
    + 3 NSURLSession (in Foundation) private-truncated'''
        result = diagnostic.sample_classification(raw, complete=False)
        self.assertEqual(result["classification_scope"], "partial_prefix")
        self.assertTrue(result["positive_evidence_only"])
        self.assertFalse(result["sample_complete"])
        self.assertFalse(result["absence_excludes_cause"])
        self.assertTrue(result["wait_hints"]["security_wait"])
        self.assertNotIn("network_frames", result["frame_counts"])
        self.assertTrue(all(result["frame_counts"].values()))
        self.assertTrue(all(result["wait_hints"].values()))
        self.assertNotIn("private", json.dumps(result))

    def test_capped_sampler_retains_partial_classification_without_claiming_completion(self):
        process = mock.Mock(pid=123)
        process.poll.return_value = None
        raw = b"    + 1 flock (in libsystem_kernel.dylib) + 1\nprivate-truncated"
        with mock.patch.object(diagnostic.sys, "platform", "darwin"), \
             mock.patch.object(diagnostic.os, "getuid", return_value=501, create=True), \
             mock.patch.object(diagnostic.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="501\n")), \
             mock.patch.object(diagnostic, "bounded_sample_output", return_value=({"status": "failed", "output_capped": True,
                "reason": "sample_output_limit", "raw_stack_saved": False}, raw)):
            result = diagnostic.timeout_sample(process, {})
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["frame_counts"]["file_lock_frames"], 1)
        self.assertTrue(result["positive_evidence_only"])
        self.assertNotIn("private", json.dumps(result))

    def test_network_hint_requires_same_branch_context_and_not_just_kernel_wait(self):
        raw = b'''    + 1 -[NSURLSession dataTaskWithRequest:] (in Foundation) + 1
    + ! 1 poll (in libsystem_kernel.dylib) + 1
'''
        self.assertTrue(diagnostic.classify_sample(raw)["wait_hints"]["network_wait"])
        sibling = raw.replace(b"+ ! 1 poll", b"+ 1 poll")
        self.assertFalse(diagnostic.classify_sample(sibling)["wait_hints"]["network_wait"])
        self.assertFalse(diagnostic.classify_sample(raw.splitlines(keepends=True)[1])["wait_hints"]["network_wait"])

    @unittest.skipIf(os.name == "nt", "Cache directory-FD fixture requires POSIX")
    def test_cache_metadata_is_bounded_name_free_and_does_not_follow_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cache = root / "cache"
            (cache / "private-framework.xcframework").mkdir(parents=True)
            (cache / "private-archive.zip").write_bytes(b"123")
            (cache / "private-download.partial").write_bytes(b"1234")
            (cache / "private-framework.xcframework/private-header").write_bytes(b"12345")
            outside = root / "outside"
            outside.mkdir()
            (outside / "private-file").write_bytes(b"do-not-count" * 100)
            (cache / "private-alias").symlink_to(outside, target_is_directory=True)
            result = diagnostic.bounded_cache_metadata(root, "cache")
            self.assertEqual(result["status"], "complete")
            self.assertEqual(result["regular_bytes"], 12)
            self.assertEqual(result["file_count"], 3)
            self.assertEqual(result["symlink_count"], 1)
            self.assertEqual(result["xcframework_count"], 1)
            self.assertEqual(result["zip_file_count"], 1)
            self.assertEqual(result["temporary_suffix_file_count"], 1)
            self.assertNotIn("private", json.dumps(result))
            self.assertNotIn(str(root), json.dumps(result))
            self.assertTrue(diagnostic.bounded_cache_metadata(root, "cache", entry_limit=1)["truncated"])
            self.assertTrue(diagnostic.bounded_cache_metadata(root, "cache", time_limit=0)["truncated"])
            (root / "alias").symlink_to(cache, target_is_directory=True)
            self.assertEqual(diagnostic.bounded_cache_metadata(root, "alias")["status"], "unavailable")

    def test_cache_snapshot_uses_fixed_locations_and_safe_labels(self):
        with mock.patch.object(diagnostic, "bounded_cache_metadata", return_value={"status": "missing"}) as count, \
             mock.patch.object(diagnostic.Path, "home", return_value=Path("/fixture-home")):
            result = diagnostic.cache_snapshot(Path("/fixture-project"))
        self.assertEqual(set(result), {"project_artifacts", "project_checkouts", "project_repositories", "user_artifacts"})
        self.assertEqual(count.call_args_list[-1].args, (Path("/fixture-home"), "Library/Caches/org.swift.swiftpm/artifacts"))
        self.assertNotIn("fixture", json.dumps(result))

    def test_shipped_symbols_require_exact_image_callgraph_and_safe_signature(self):
        for value in ("/private/source", r"C:\private\source", "https://user:secret@host/repo?token=value",
                      "user@example.invalid", "function?token=private", "function=private", "function\t",
                      "function\x1bprivate", "function0xdeadbeef", "foo.swift:12", "foo.cpp:12", "éclair"):
            with self.subTest(value=value):
                self.assertIsNone(diagnostic.safe_shipped_symbol(value, "Foundation"))
        self.assertIsNone(diagnostic.safe_shipped_symbol("private_token", "xcodebuild"))
        self.assertIsNone(diagnostic.safe_shipped_symbol("private_token", "FlutterGeneratedPluginSwiftPackage-manifest"))
        self.assertIsNone(diagnostic.safe_shipped_symbol("private_token", "ProjectSource"))
        self.assertIsNone(diagnostic.safe_shipped_symbol("A" * 161, "Foundation"))
        self.assertEqual(diagnostic.safe_shipped_symbol("-[NSURLSession dataTaskWithRequest:] + 123", "Foundation"),
                         "-[NSURLSession dataTaskWithRequest:]")
        raw = b'''    + 1 BeforeGraph (in Foundation) + 123
Call graph:
    + 1 -[NSURLSession dataTaskWithRequest:] (in Foundation) + 0xfeed /private/source
    + 1 private_token (in ProjectSource) + 5
    + 1 private_token (in xcodebuild) + 5
    + 1 private_token (in FlutterGeneratedPluginSwiftPackage-manifest) + 5
Binary Images:
    + 1 AfterGraph (in Foundation) + 123
'''
        result = diagnostic.shipped_sample_symbols(raw)
        self.assertEqual(result["shipped_symbols"], [{"image": "Foundation", "symbol": "-[NSURLSession dataTaskWithRequest:]", "observed_count": 1}])
        serialized = json.dumps(result)
        for forbidden in ("private", "0xfeed", "BeforeGraph", "AfterGraph", "ProjectSource", "xcodebuild", "manifest"):
            self.assertNotIn(forbidden, serialized)

    def test_shipped_symbol_caps_prioritize_package_network_security_over_kernel_waits(self):
        lines = ["Call graph:"]
        lines += [f"    + 1 KernelWait{index} (in libsystem_kernel.dylib) + 1" for index in range(50)]
        for image in ("SwiftPM", "IDEPackageSupport", "Security", "CFNetwork"):
            lines += [f"    + 1 PublicFunction{index} (in {image}) + 1" for index in range(12)]
        lines.append("    + 1 PublicFunction0 (in Security) + 5")
        result = diagnostic.shipped_sample_symbols("\n".join(lines).encode())
        selected = result["shipped_symbols"]
        self.assertEqual(len(selected), 32)
        self.assertEqual({item["image"] for item in selected}, {"SwiftPM", "IDEPackageSupport", "Security", "CFNetwork"})
        for image in {item["image"] for item in selected}:
            self.assertEqual(sum(item["image"] == image for item in selected), 8)
        duplicate = next(item for item in selected if item["image"] == "Security" and item["symbol"] == "PublicFunction0")
        self.assertEqual(duplicate["observed_count"], 2)
        self.assertTrue(result["shipped_symbol_summary"]["positive_evidence_only"])
        self.assertGreater(result["shipped_symbol_summary"]["omitted_unique_count"], 0)

    def test_partial_shipped_symbols_do_not_keep_truncated_frame_or_imply_absence(self):
        raw = b"Call graph:\n    + 1 SecItemCopyMatching (in Security) + 1\n    + 1 private-truncated (in Foundation)"
        result = diagnostic.sample_classification(raw, complete=False)
        self.assertEqual(result["shipped_symbols"], [{"image": "Security", "symbol": "SecItemCopyMatching", "observed_count": 1}])
        self.assertTrue(result["positive_evidence_only"])
        self.assertFalse(result["absence_excludes_cause"])
        self.assertFalse(result["root_cause_established"])
        self.assertNotIn("private", json.dumps(result))

    def test_verified_apple_package_graph_and_swift_runtime_images_are_allowlisted(self):
        raw = b'''Call graph:
    + 1 PackageGraphWorkspace.resolve (in IDESwiftPackageCore) + 1
    + 1 DeveloperDirectory.lookup (in DVTDeveloperFoundation) + 1
    + 1 swift_task_switch (in libswift_Concurrency.dylib) + 1
    + 1 swift_release (in libswiftCore.dylib) + 1
'''
        result = diagnostic.shipped_sample_symbols(raw)
        self.assertEqual({item["image"] for item in result["shipped_symbols"]},
                         {"IDESwiftPackageCore", "DVTDeveloperFoundation", "libswift_Concurrency.dylib", "libswiftCore.dylib"})
        self.assertEqual(result["shipped_symbols"][0]["image"], "IDESwiftPackageCore")


if __name__ == "__main__":
    unittest.main()
