#!/usr/bin/env python3
"""Audit and upload explicit debug companions, never source or release binaries.

Windows builds must supply the CMake-generated Release manifest and matching
PDBs. --audit-only is entirely offline and does not need an auth token. CI keeps
the resulting JSON as the build's symbol evidence, without absolute paths.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

CLI_VERSION = "2.58.4"
PROJECTS = {"brand_a": "omofly", "brand_b": "daishu"}
REQUIRED_WINDOWS_TARGETS = {"FlClash", "flutter_inappwebview_windows_plugin"}


class SymbolError(RuntimeError):
    pass


def run_cli(cli: str, arguments: list[str]) -> str:
    # No token on the command line; never relay verbose diagnostics, response
    # bodies, configuration, or absolute paths into public CI output.
    result = subprocess.run(
        [cli, *arguments], capture_output=True, text=True, encoding="utf-8",
        errors="replace", timeout=900,
        env={**os.environ, "SENTRY_LOG_LEVEL": "warn"},
    )
    # `check --json` returns 1 for a PE with a valid debug ID but no embedded
    # unwind/debug sections. Its matching PDB can still be fully usable.
    check_metadata = arguments[:3] == ["debug-files", "check", "--json"]
    if result.returncode and not (check_metadata and result.returncode == 1 and result.stdout.lstrip().startswith("{")):
        raise SymbolError(
            f"sentry-cli {' '.join(arguments[:2])} failed (exit {result.returncode}); "
            "check authentication, project permissions, network and symbol validity"
        )
    return result.stdout


def check_symbol(cli: str, path: Path, expected_type: str | None = None) -> dict:
    if not path.is_file():
        raise SymbolError(f"Missing debug artifact: {path.name}")
    try:
        info = json.loads(run_cli(cli, ["debug-files", "check", "--json", str(path)]))
    except json.JSONDecodeError as error:
        raise SymbolError("sentry-cli returned invalid symbol metadata") from error
    ids = {v["debug_id"].lower() for v in info.get("variants", [])
           if re.fullmatch(r"[a-fA-F0-9-]+", v.get("debug_id", ""))
           and v["debug_id"].replace("-", "").strip("0")}
    if not ids or (expected_type != "pe" and not info.get("is_usable")):
        raise SymbolError(f"Unusable debug information: {path.name}")
    if expected_type and info.get("type") != expected_type:
        raise SymbolError(f"Unexpected symbol format: {path.name}")
    return {"debug_ids": sorted(ids), "format": info["type"],
            "features": info.get("features", "")}


def fingerprint(path: Path) -> dict:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"name": path.name, "bytes": path.stat().st_size,
            "sha256": digest.hexdigest()}


def audit_windows(cli: str, build_root: Path) -> tuple[list[Path], list[dict]]:
    manifests = list(build_root.glob("**/sentry-symbols/Release/targets.tsv"))
    if len(manifests) != 1:
        raise SymbolError("Expected one fresh Windows Release target manifest")
    artifacts, evidence, targets, binaries = [], [], set(), {}
    for row in manifests[0].read_text(encoding="utf-8").splitlines():
        fields = row.split("\t")
        if len(fields) != 3 or not re.fullmatch(r"[A-Za-z0-9_.+-]+", fields[0]):
            raise SymbolError("Invalid Windows target manifest")
        target, binary_name, pdb_name = fields
        if target in targets:
            raise SymbolError("Duplicate Windows symbol target")
        targets.add(target)
        binary, pdb = Path(binary_name), Path(pdb_name)
        binaries[target] = binary
        for artifact in (binary, pdb):
            if not artifact.resolve().is_relative_to(build_root.resolve()):
                raise SymbolError("Windows symbol artifact escaped its build root")
        if pdb.suffix.lower() != ".pdb" or binary.suffix.lower() not in (".exe", ".dll"):
            raise SymbolError("Windows manifest contains a non-native artifact")
        binary_info = check_symbol(cli, binary, "pe")
        pdb_info = check_symbol(cli, pdb, "pdb")
        if binary_info["debug_ids"] != pdb_info["debug_ids"]:
            raise SymbolError(f"Binary/PDB debug identifier mismatch: {target}")
        if "debug" not in pdb_info["features"].split(", "):
            raise SymbolError(f"PDB is missing line debug information: {target}")
        artifacts.append(pdb)
        evidence.append({"target": target, "binary": fingerprint(binary),
                         "symbols": fingerprint(pdb), **pdb_info})
    if not REQUIRED_WINDOWS_TARGETS <= targets:
        raise SymbolError("Windows symbols must cover the runner and tutorial plugin")
    bundle = binaries["FlClash"].parent
    for target, binary in binaries.items():
        if target == "FlClash" or target.endswith("_plugin"):
            installed = bundle / binary.name
            if not installed.is_file() or fingerprint(installed)["sha256"] != fingerprint(binary)["sha256"]:
                raise SymbolError(f"Bundle does not contain the matching native binary: {target}")
    return artifacts, evidence


def collect_companions(cli: str, root: Path, platform: str) -> tuple[list[Path], list[dict]]:
    artifacts, evidence = [], []
    # Flutter's TargetPlatform.darwin differs from our workflow's macos label.
    # getNameForTargetPlatform supplies darwin-{x86_64,arm64}, not macos-*.
    dart_platform = "darwin" if platform == "macos" else platform
    for path in sorted((root / "debug-info").glob(f"app.{dart_platform}-*.symbols")):
        info = check_symbol(cli, path)
        if info["format"] not in ("elf", "dsym"):
            raise SymbolError("Unexpected Dart debug companion format")
        artifacts.append(path)
        evidence.append({"symbols": fingerprint(path), **info})
    if platform == "macos":
        for bundle in sorted((root / "macos/Build/Products/Release").glob("**/*.dSYM")):
            for path in sorted((bundle / "Contents/Resources/DWARF").glob("*")):
                if path.is_file():
                    info = check_symbol(cli, path, "dsym")
                    artifacts.append(path)
                    evidence.append({"symbols": fingerprint(path), **info})
    if platform != "macos" and not artifacts:
        raise SymbolError("No Dart split debug information was generated")
    return artifacts, evidence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("windows", "android", "linux", "macos"), required=True)
    parser.add_argument("--flavor", choices=PROJECTS, required=True)
    parser.add_argument("--build-root", type=Path, default=Path("build"))
    parser.add_argument("--evidence", type=Path, default=Path("build/sentry-symbols-evidence.json"))
    parser.add_argument("--sentry-cli", default="sentry-cli")
    parser.add_argument("--product-version")
    parser.add_argument("--build-number")
    parser.add_argument("--source-revision")
    parser.add_argument("--audit-only", action="store_true")
    args = parser.parse_args(argv)
    evidence = {"schema_version": 1, "platform": args.platform, "flavor": args.flavor,
                "cli_version": CLI_VERSION, "source_upload": False,
                "release_binary_upload": False, "status": "not_started"}
    try:
        for key, value, pattern in (
            ("product_version", args.product_version, r"[0-9]+\.[0-9]+\.[0-9]+(?:[.+-][A-Za-z0-9.-]+)?"),
            ("build_number", args.build_number, r"[0-9]+"),
            ("source_revision", args.source_revision, r"[a-fA-F0-9]{7,64}"),
        ):
            if value is not None:
                if not re.fullmatch(pattern, value):
                    raise SymbolError(f"Invalid safe build metadata: {key}")
                evidence[key] = value
        cli = shutil.which(args.sentry_cli)
        if not cli:
            raise SymbolError(f"Install @sentry/cli@{CLI_VERSION} before symbol audit")
        version = run_cli(cli, ["--version"]).strip()
        if version != f"sentry-cli {CLI_VERSION}":
            raise SymbolError(f"Expected sentry-cli {CLI_VERSION}")
        if args.platform == "windows":
            native, native_evidence = audit_windows(cli, args.build_root / "windows")
        else:
            native, native_evidence = [], []
        dart, dart_evidence = collect_companions(cli, args.build_root, args.platform)
        files = native + dart
        if not files:
            raise SymbolError("No uploadable debug companions found")
        evidence.update(status="audited", native=native_evidence, companions=dart_evidence)
        if args.platform in ("android", "linux"):
            evidence["native_coverage"] = "pending_separate_debug_companions"
        if args.audit_only:
            print(f"Sentry offline audit passed: {len(files)} debug companions")
        elif not os.environ.get("SENTRY_AUTH_TOKEN", "").strip():
            if args.platform == "windows":
                raise SymbolError("Windows release requires SENTRY_AUTH_TOKEN for matching native symbols")
            evidence["status"] = "skipped_missing_token"
            print("Sentry upload explicitly skipped: SENTRY_AUTH_TOKEN is missing")
        else:
            # Stage only allowlisted companions. No recursive repository/build
            # scan, binary, flavor, env.json, DSN, or include-sources option.
            with tempfile.TemporaryDirectory(prefix="xflclash-sentry-") as temporary:
                stage = Path(temporary)
                for index, path in enumerate(files):
                    destination = stage / str(index) / path.name
                    destination.parent.mkdir()
                    shutil.copyfile(path, destination)
                upload_arguments = [
                    "debug-files", "upload", "--org", "ka-chiu-lee",
                    "--project", PROJECTS[args.flavor], "--no-sources",
                    "--no-zips", "--wait-for", "300", "--require-all",
                ]
                for debug_id in sorted({
                    identifier for item in native_evidence + dart_evidence
                    for identifier in item["debug_ids"]
                }):
                    upload_arguments.extend(["--id", debug_id])
                upload_arguments.append(str(stage))
                run_cli(cli, upload_arguments)
            evidence["status"] = "uploaded_and_processed"
            print(f"Sentry accepted and processed {len(files)} debug companions")
    except (SymbolError, OSError, subprocess.TimeoutExpired) as error:
        evidence["status"] = "failed"
        # Error strings are constructed locally; no raw CLI stderr or tokens.
        evidence["error"] = str(error) if isinstance(error, SymbolError) else type(error).__name__
        print(f"Sentry symbols failed: {evidence['error']}", file=sys.stderr)
        return_code = 1
    else:
        return_code = 0
    finally:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
