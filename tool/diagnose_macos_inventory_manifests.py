#!/usr/bin/env python3
"""Compare local manifest evaluation in a shell and a tiny Xcode script phase.

This diagnostic never builds the Flutter client, resolves packages, uploads
symbols or reads Sentry credentials. Resolved checkouts must already exist.
Only fixed status codes, audited package labels and numeric observations enter
the report. Compiler/Xcode output, paths and environment values are discarded.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import sentry_macos_inventory as inventory
from pick_sentry_symbolication_probe import ProbeError, diagnose_macho_line_rows, pick_macho
from resolve_macos_packages import child_environment
from sentry_macho import MachoError, inspect_macho


MODES = ("shell", "xcode_original", "xcode_host")
ENVIRONMENT_KEYS = ("SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS", "SWIFT_EXEC", "SWIFT_EXEC_MANIFEST",
                    "SWIFTPM_CUSTOM_LIBS_DIR", "SWIFTPM_MODULECACHE_OVERRIDE", "DYLD_LIBRARY_PATH",
                    "DYLD_FRAMEWORK_PATH", "MACOSX_DEPLOYMENT_TARGET")


def run_quiet(arguments, *, cwd=None, environment=None, timeout=120, heartbeat=False):
    """Bound a private command and its POSIX descendants; never capture output."""
    started = time.monotonic()
    try:
        process = subprocess.Popen(arguments, cwd=cwd, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return {"status": "failed", "reason": "command_unavailable"}
    try:
        while True:
            try:
                code = process.wait(timeout=max(0, min(30, started + timeout - time.monotonic())))
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() >= started + timeout:
                    raise
                if heartbeat:
                    print("inventory_manifest_diagnostic: phase_running", flush=True)
        return {"status": "complete" if code == 0 else "failed",
                "reason": "command_completed" if code == 0 else "command_nonzero_exit",
                "exit_code": code, "elapsed_seconds": round(time.monotonic() - started, 2)}
    except subprocess.TimeoutExpired:
        for signum in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass
            if signum == signal.SIGTERM:
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            return {"status": "failed", "reason": "command_cleanup_failed"}
        return {"status": "failed", "reason": "command_timeout",
                "elapsed_seconds": round(time.monotonic() - started, 2)}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def worker_command(project, mode, report):
    return [sys.executable, str(Path(__file__).resolve()), "--worker", "--mode", mode,
            "--project-root", str(project), "--report", str(report)]


def write_xcode_project(root, project, reports):
    """An aggregate target with one script, no sources/packages/client links."""
    bundle = root / "ManifestProbe.xcodeproj"
    bundle.mkdir()
    script = "set -eu\n" + "\n".join(
        shlex.join(worker_command(project, mode, reports[mode]))
        for mode in MODES[1:]) + "\n"
    # JSON quoted strings are valid PBX quoted strings, including escaped
    # newlines and quotes; shell arguments are separately quoted above.
    objects = """
 A00000000000000000000001 = {isa = PBXProject; buildConfigurationList = A00000000000000000000002; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A00000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000004);};
 A00000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000005); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};
 A00000000000000000000003 = {isa = PBXGroup; children = (); sourceTree = "<group>";};
 A00000000000000000000004 = {isa = PBXAggregateTarget; buildConfigurationList = A00000000000000000000006; buildPhases = (A00000000000000000000007); dependencies = (); name = ManifestProbe; productName = ManifestProbe;};
 A00000000000000000000005 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 11.0;}; name = Release;};
 A00000000000000000000006 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000008); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};
 A00000000000000000000007 = {isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); name = "Evaluate selected manifests"; outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; showEnvVarsInLog = 0; shellScript = SCRIPT_VALUE;};
 A00000000000000000000008 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 11.0; ENABLE_USER_SCRIPT_SANDBOXING = NO; CODE_SIGNING_ALLOWED = NO;}; name = Release;};
""".replace("SCRIPT_VALUE", json.dumps(script, ensure_ascii=True))
    (bundle / "project.pbxproj").write_text(
        "// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
        + objects + "}; rootObject = A00000000000000000000001;}\n", encoding="utf-8")
    return bundle


def macho_debug_preflight(binary, dwarf, architecture):
    """Reject an empty dsymutil result before asking atos for source lines."""
    result = {"status": "failed", "uuid_matches": False, "has_debug_info": False,
              "has_debug_line": False, "dsym_without_executable_text": False, "positive_rows": 0}
    try:
        runtime = next(item for item in inspect_macho(binary)["variants"] if item["architecture"] == architecture)
        debug = next(item for item in inspect_macho(dwarf)["variants"] if item["architecture"] == architecture)
        result.update(uuid_matches=bool(runtime["uuid"]) and runtime["uuid"] == debug["uuid"],
                      has_debug_info=debug["has_debug_info"], has_debug_line=debug["has_debug_line"],
                      dsym_without_executable_text=debug["filetype"] == 10 and not debug["has_executable_text"])
        if not all(result[key] for key in ("uuid_matches", "has_debug_info", "has_debug_line", "dsym_without_executable_text")):
            return result
        rows = diagnose_macho_line_rows(binary, dwarf, architecture, candidate_limit=0, lookup_timeout=10)
        result["line_table"] = rows
        result["positive_rows"] = rows["in_range_row_count"]
        if rows["status"] == "complete" and result["positive_rows"] > 0:
            result["status"] = "complete"
    except Exception:
        pass
    return result


def macho_smoke(root, environment):
    """Validate picker parsing against real native nm/atos and tiny line info."""
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        return {"status": "failed", "reason": "unsupported_host_architecture"}
    source, obj, binary, dsym = (root / name for name in ("ManifestProbe.c", "ManifestProbe.o", "ManifestProbe", "ManifestProbe.dSYM"))
    source.write_text("__attribute__((noinline)) int manifest_probe_function(void) { return 7; }\n"
                      "int main(void) { return manifest_probe_function(); }\n", encoding="utf-8")
    stages, lookup = {}, {}
    for phase, command in (("compile", ["xcrun", "clang", "-g", "-O0", "-c", str(source), "-o", str(obj)]),
                           ("link", ["xcrun", "clang", "-g", "-O0", str(obj), "-o", str(binary)]),
                           ("dsym", ["xcrun", "dsymutil", str(binary), "-o", str(dsym)])):
        if phase != "compile" and not obj.is_file():
            return {"status": "failed", "reason": "macho_fixture_object_unavailable", "stages": stages}
        result = run_quiet(command, cwd=root, environment=environment)
        stages[phase] = result
        if result["status"] != "complete":
            return {"status": "failed", "reason": "macho_fixture_" + phase + "_failed", "stages": stages}
    dwarf = dsym / "Contents/Resources/DWARF/ManifestProbe"
    result = {"status": "failed", "architecture": architecture, "stages": stages, "lookup": lookup}
    stages["debug_information"] = macho_debug_preflight(binary, dwarf, architecture)
    if stages["debug_information"]["status"] != "complete":
        result["reason"] = "macho_fixture_debug_information_unavailable"
        return result
    try:
        _, expected = pick_macho(binary, dwarf, architecture, diagnostics=lookup, candidate_limit=12, lookup_timeout=10)
        if expected["filename"] != source.name or expected["lineno"] <= 0:
            raise ProbeError("unexpected_fixture_source")
    except (OSError, ValueError, KeyError, ProbeError, MachoError):
        result["reason"] = "native_nm_atos_smoke_failed"
    else:
        result.update(status="complete", native_nm_atos_parsed=True, source_line_positive=True)
    result["line_pc_diagnostic"] = diagnose_macho_line_rows(binary, dwarf, architecture,
        candidate_limit=max(0, 12 - lookup.get("attempts", 0)), lookup_timeout=10)
    return result


def worker(project, mode, report):
    # The shared inventory helper owns graph selection, safe error projection
    # and host-environment policy. Never duplicate its manifest parser here.
    environment = dict(os.environ)
    swift = None if mode == "xcode_host" else shutil.which("swift") or "/usr/bin/swift"
    result = inventory.diagnose_manifests(project, project / "build", environment=environment,
                                         environment_mode="host" if mode == "xcode_host" else "inherited", swift=swift)
    value = {"mode": mode, "environment_present": {key: bool(environment.get(key)) for key in ENVIRONMENT_KEYS},
             "tool_selection": "host_xcrun" if mode == "xcode_host" else "original_path",
             **result}
    write_json(report, value)
    # Failed evaluations are diagnostic data. Keep the phase alive so that
    # the other environment runs and the parent can inspect all reports.
    return 0


def diagnose(project, report):
    value = {"schema_version": 1, "status": "failed", "client_build_performed": False,
             "scope": "all", "manifest_validation_performed": True,
             "package_resolution_performed": False, "rootcause_proven": False,
             "runner_environment_equivalence_proven": False, "xcode_target_kind": "minimal_aggregate", "modes": []}
    environment = child_environment(dict(os.environ))
    build = project / "build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".inventory-manifest-diagnostic-", dir=build) as temporary:
        root = Path(temporary).resolve()
        reports = {mode: root / (mode + ".json") for mode in MODES}
        print("inventory_manifest_diagnostic: shell_phase_started", flush=True)
        value["shell_phase"] = run_quiet(worker_command(project, "shell", reports["shell"]),
                                         cwd=project, environment=environment, timeout=300, heartbeat=True)
        bundle = write_xcode_project(root, project, reports)
        print("inventory_manifest_diagnostic: xcode_phase_started", flush=True)
        value["xcode_phase"] = run_quiet(
            ["xcrun", "xcodebuild", "-project", str(bundle), "-target", "ManifestProbe", "-configuration", "Release",
             "CODE_SIGNING_ALLOWED=NO", "build"], cwd=root, environment=environment, timeout=600, heartbeat=True)
        for mode in MODES:
            try:
                value["modes"].append(json.loads(reports[mode].read_text()))
            except (OSError, ValueError):
                value["modes"].append({"mode": mode, "status": "failed", "reason": "mode_report_unavailable"})
        value["native_lookup_smoke"] = macho_smoke(root, environment)
    if (value["shell_phase"]["status"] == "complete" and value["xcode_phase"]["status"] == "complete"
            and value["native_lookup_smoke"]["status"] == "complete"
            and all(item["status"] == "complete" for item in value["modes"])):
        value["status"] = "complete"
    write_json(report, value)
    print("inventory_manifest_diagnostic: " + value["status"], flush=True)
    return 0 if value["status"] == "complete" else 1


def diagnose_native_only(project, report):
    environment = child_environment(dict(os.environ))
    build = project / "build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".native-lookup-diagnostic-", dir=build) as temporary:
        smoke = macho_smoke(Path(temporary).resolve(), environment)
    value = {"schema_version": 1, "scope": "native_lookup_only", "status": smoke["status"],
             "client_build_performed": False, "package_resolution_performed": False,
             "manifest_validation_performed": False, "rootcause_proven": False, "native_lookup_smoke": smoke}
    write_json(report, value)
    print("inventory_manifest_diagnostic: native_lookup_" + value["status"], flush=True)
    return 0 if value["status"] == "complete" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--project-root", type=Path, default=Path("."))
    parser.add_argument("--report", type=Path, default=Path("build/sentry-inventory-manifest-diagnostic.json"))
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--native-lookup-only", action="store_true", help="Run only the tiny native lookup fixture; never validate manifests")
    parser.add_argument("--mode", choices=MODES, default="shell", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if sys.platform != "darwin":
            raise ValueError()
        project = args.project_root.resolve()
        if args.native_lookup_only and args.worker:
            raise ValueError()
        if args.native_lookup_only:
            return diagnose_native_only(project, args.report)
        if not (project / "macos/Runner.xcodeproj/project.pbxproj").is_file():
            raise ValueError()
        return worker(project, args.mode, args.report) if args.worker else diagnose(project, args.report)
    except Exception:
        # External errors can carry source paths, private URLs or environment.
        try:
            write_json(args.report, {"schema_version": 1, "status": "failed", "reason": "diagnostic_execution_failed",
                                     "scope": "native_lookup_only" if args.native_lookup_only else "all",
                                     "manifest_validation_performed": False, "client_build_performed": False})
        except (OSError, ValueError):
            pass
        print("inventory_manifest_diagnostic: diagnostic_execution_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
