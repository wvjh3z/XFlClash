#!/usr/bin/env python3
"""Shared, offline release gate used locally and before the platform matrix.

Requires POSIX + Bash/Git/CMake/C++; no Flutter, SDK, brand secrets or client builds.
Pure structure checks can independently run on any supported Python host.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULES = (
    "tool.test.build_diagnostics_test",
    "tool.test.local_release_automation_test.AndroidLocalTests.test_diagnostics_survive_clean_and_keep_original_outcomes",
    "tool.test.local_release_automation_test.AndroidLocalTests.test_finalizer_error_cannot_change_success_or_failure",
    "tool.test.native_hook_diagnostics_test",
    "tool.test.prepare_go_dependencies_test",
    "tool.test.sentry_symbolication_picker_test.PickerTest.test_native_cleanup_guard_rejects_unreaped_child",
    "tool.test.sentry_symbolication_picker_test.PickerTest.test_native_tool_stderr_is_bounded_and_safe",
    "tool.test.sentry_symbolication_picker_test.PickerTest.test_native_timeout_after_ready_uses_controlled_clock",
    "tool.test.sentry_symbolication_picker_test.PickerTest.test_native_capacity_after_slow_start_is_not_timeout",
    "tool.test.python_text_encoding_test",
    "tool.test.appimage_restart_test",
    "tool.test.webkit_probe_support_test",
    "tool.test.release_request_test",
    "tool.test.brand_identity_cli_test.CatalogTests",
    "tool.test.android_ndk_environment_test",
    "tool.test.android_brand_icon_resources_test",
    "tool.test.android_package_fixture_test",
    "tool.test.linux_appimage_readback_test.ContainerHeaderTests",
    "tool.test.desktop_build_number_test",
    "tool.test.release_entry_contract_test",
    "tool.test.release_build_number_test",
    "tool.test.sentry_release_workflow_test",
    "tool.test.release_preflight_test",
    "tool.test.release_pipeline_test",
    "tool.test.macos_final_inventory_test",
    "tool.test.linux_release_packages_test.ArchiveSafetyTests",
    "tool.test.fallback_assets_test",
    "tool.test.windows_webview_shutdown_test",
    "tool.test.packager_context_test",
    "tool.test.distributor_fixture_test",
    "tool.test.distributor_preflight_test",
    "tool.test.build_asset_download_test",
    "tool.test.prepare_test_gradle_test",
    "tool.test.sentry_upload_confirmation_test",
    "tool.test.local_release_automation_test.CliOutputEncodingTests",
)


def requirements():
    missing = [name for name in ("bash", "git", "cmake", "c++") if not shutil.which(name)]
    if os.name != "posix":
        missing.insert(0, "POSIX host (use Linux/WSL/macOS for the complete gate)")
    return missing


def run_suite(suite, *, stream=None):
    result = unittest.TextTestRunner(stream=stream, verbosity=1).run(suite)
    passed = result.testsRun > 0 and result.wasSuccessful() and not result.skipped
    summary = {"tests": result.testsRun, "failures": len(result.failures),
               "errors": len(result.errors), "skipped": len(result.skipped), "passed": passed}
    print("Release workflow preflight: " + json.dumps(summary), file=stream or sys.stdout)
    return 0 if passed else 1


def main():
    missing = requirements()
    if missing:
        print("Release preflight prerequisites missing: " + ", ".join(missing), file=sys.stderr)
        return 2
    # Imports and file-based fixtures resolve the same committed checkout in CI/local.
    sys.path.insert(0, str(ROOT))
    os.chdir(ROOT)
    suite = unittest.defaultTestLoader.loadTestsFromNames(MODULES)
    return run_suite(suite)


if __name__ == "__main__":
    raise SystemExit(main())
