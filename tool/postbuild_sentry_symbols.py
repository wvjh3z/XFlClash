#!/usr/bin/env python3
"""One explicit release entry for offline symbol preparation and Sentry upload.

No builds are started here. A configured release fails closed when the pinned
CLI, upload token, matching symbols or upload processing are unavailable.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from prepare_sentry_windows_assets import prepare_windows_assets
from upload_sentry_symbols import SymbolError


CLI_VERSION = "2.58.4"
PLATFORMS = ("android", "linux", "windows", "macos")


class ReleaseError(RuntimeError):
    pass


def resolve_cli(value: str | None, environment: dict[str, str]) -> str:
    cli = shutil.which(value or environment.get("SENTRY_CLI", "sentry-cli"),
                       path=environment.get("PATH"))
    if not cli:
        raise ReleaseError(f"Install sentry-cli {CLI_VERSION} or set SENTRY_CLI to its executable")
    # CLI output is UTF-8 regardless of the Windows ANSI code page. Diagnostics
    # must not raise a locale decode error before exit/version checks run.
    # Replacement characters in stdout cannot match the required ASCII version.
    result = subprocess.run([cli, "--version"], capture_output=True, text=True,
                            encoding="utf-8", errors="replace",
                            env=environment, timeout=30)
    if result.returncode or result.stdout.strip() != f"sentry-cli {CLI_VERSION}":
        raise ReleaseError(f"Release symbols require sentry-cli {CLI_VERSION}")
    return cli


def upload_environment(root: Path, environment: dict[str, str], audit_only: bool) -> dict[str, str]:
    result = dict(environment)
    result.pop("SENTRY_MAINTENANCE_TOKEN", None)
    if audit_only:
        # An offline audit must not acquire credentials unnecessarily.
        result.pop("SENTRY_AUTH_TOKEN", None)
        return result
    if not result.get("SENTRY_AUTH_TOKEN", "").strip():
        token_path = Path(result.get("SENTRY_AUTH_TOKEN_FILE", str(root / "flavors/sentry-cli.token")))
        try:
            token = token_path.read_text(encoding="utf-8").strip()
        except (OSError, UnicodeError):
            raise ReleaseError("Release symbols require SENTRY_AUTH_TOKEN or a readable upload-token file") from None
        if not token or any(character.isspace() for character in token):
            raise ReleaseError("The Sentry upload-token file is empty or invalid")
        result["SENTRY_AUTH_TOKEN"] = token
    # The maintenance credential is deliberately never considered a fallback.
    return result


def run_checked(arguments: list[str], *, root: Path, environment: dict[str, str]) -> None:
    result = subprocess.run(arguments, cwd=root, env=environment)
    if result.returncode:
        raise ReleaseError("Symbol preparation, audit or upload failed; release remains incomplete")


def write_outcome(path: Path, data: dict) -> None:
    """Atomically replace only this invocation's small, credential-free report."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.sentry-outcome-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(data, stream, indent=2)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    parser.add_argument("--flavor", required=True, choices=("brand_a", "brand_b"))
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--build-root", type=Path, default=Path("build"))
    parser.add_argument("--defines", type=Path, default=Path("flavor_defines.json"))
    parser.add_argument("--package", type=Path, action="append", default=[])
    parser.add_argument("--expected-abi", action="append", choices=("armeabi-v7a", "arm64-v8a", "x86_64"), default=[])
    parser.add_argument("--architecture", choices=("x64", "arm64"))
    parser.add_argument("--app", type=Path)
    parser.add_argument("--sentry-cli")
    parser.add_argument("--product-version")
    parser.add_argument("--build-number")
    parser.add_argument("--source-revision")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--preflight", action="store_true",
                        help="Check configuration, pinned CLI and upload credentials without reading symbols")
    parser.add_argument("--reuse-prepared", action="store_true",
                        help="Audit/upload a saved matching symbol archive without regenerating or building")
    diagnostic = parser.add_mutually_exclusive_group()
    diagnostic.add_argument("--audit-only", action="store_true", help="Explicit offline diagnostic; do not upload")
    diagnostic.add_argument("--no-sentry", action="store_true", help="Explicit diagnostic; skip Sentry work")
    args = parser.parse_args(argv)
    root = args.project_root.resolve()
    evidence_path = args.evidence or args.build_root / 'sentry-symbols-evidence.json'
    evidence_path = evidence_path if evidence_path.is_absolute() else root / evidence_path
    identity = dict(platform=args.platform, flavor=args.flavor)
    stage = 'configuration'
    try:
        # Preflight is read-only. Every actual run, including archive reuse and
        # diagnostic skips, invalidates old success before it can fail early.
        if not args.preflight:
            evidence_path.unlink(missing_ok=True)
        if args.no_sentry:
            if not args.preflight:
                write_outcome(evidence_path, dict(identity, status='skipped', reason='explicit_diagnostic'))
            print("Sentry symbols explicitly disabled for this diagnostic build (--no-sentry)")
            return 0
        defines_path = args.defines if args.defines.is_absolute() else root / args.defines
        try:
            defines = json.loads(defines_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise ReleaseError("Prepare the selected production flavor before checking release symbols") from None
        if not isinstance(defines, dict) or defines.get("XB_FLAVOR_ID") != args.flavor:
            raise ReleaseError("Generated flavor defines do not match the selected release flavor")
        if str(defines.get("XB_DEBUG", "")).lower() != "false":
            raise ReleaseError("Release symbol automation requires production flavor defines")
        dsn = defines.get("XB_SENTRY_DSN", "")
        if not isinstance(dsn, str):
            raise ReleaseError("Generated Sentry configuration has an invalid type")
        if not dsn.strip():
            if not args.preflight:
                write_outcome(evidence_path, dict(identity, status='skipped', reason='not_configured'))
            print("Sentry symbols not required: the selected production flavor has no Sentry DSN")
            return 0
        stage = 'credentials'
        environment = upload_environment(root, dict(os.environ), args.audit_only)
        offline_environment = {key: value for key, value in environment.items() if key != "SENTRY_AUTH_TOKEN"}
        stage = 'cli'
        cli = resolve_cli(args.sentry_cli, offline_environment)
        if args.preflight:
            print("Sentry release preflight passed" + (" (offline audit only)" if args.audit_only else ""))
            return 0
        stage = 'prepare'
        if not args.reuse_prepared and args.platform == 'windows':
            prepare_windows_assets((root / args.build_root).resolve(), cli)
        common = ["--build-root", str(args.build_root)]
        if not args.reuse_prepared and args.platform in ("android", "linux"):
            prepare = [sys.executable, str(root / "tool/prepare_sentry_native_symbols.py"),
                       "--platform", args.platform, *common]
            if args.platform == "android":
                if not args.package:
                    raise ReleaseError("Android release symbols require the final APK path(s)")
                for abi in args.expected_abi:
                    prepare.extend(["--expected-abi", abi])
                for package in args.package:
                    prepare.extend(["--package", str(package)])
            elif args.architecture:
                prepare.extend(["--architecture", args.architecture])
            run_checked(prepare, root=root, environment=offline_environment)
        elif not args.reuse_prepared and args.platform == "macos":
            prepare = [sys.executable, str(root / "tool/prepare_sentry_macos_symbols.py"), *common]
            if args.app:
                prepare.extend(["--app", str(args.app)])
            run_checked(prepare, root=root, environment=offline_environment)
        upload = [sys.executable, str(root / "tool/upload_sentry_symbols.py"),
                  "--platform", args.platform, "--flavor", args.flavor, *common,
                  "--sentry-cli", cli]
        upload.extend(["--evidence", str(evidence_path)])
        for name in ("product_version", "build_number", "source_revision"):
            value = getattr(args, name)
            if value is not None:
                upload.extend(["--" + name.replace("_", "-"), str(value)])
        if args.audit_only:
            upload.append("--audit-only")
        stage = 'audit' if args.audit_only else 'upload'
        run_checked(upload, root=root, environment=environment)
        stage = 'completion'
        try:
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise ReleaseError("The symbol uploader did not write a valid completion report") from None
        expected = "audited" if args.audit_only else "uploaded_and_processed"
        if (not isinstance(evidence, dict) or evidence.get("status") != expected
                or evidence.get("platform") != args.platform or evidence.get("flavor") != args.flavor):
            raise ReleaseError("The symbol completion report does not confirm the required audit/upload result")
        return 0
    except (ReleaseError, SymbolError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        if not args.preflight:
            # Preserve current uploader diagnostics, but never a success state
            # when this coordinator failed. The old report was removed above.
            failure = dict(identity, status='failed', postbuild_stage=stage,
                           postbuild_error=type(error).__name__)
            try:
                current = json.loads(evidence_path.read_text(encoding='utf-8'))
                if (isinstance(current, dict) and current.get('status') == 'failed'
                        and all(current.get(key) == value for key, value in identity.items())):
                    failure = {**current, **failure}
            except (OSError, ValueError):
                pass
            try:
                write_outcome(evidence_path, failure)
            except OSError:
                print('Sentry failure report could not be saved', file=sys.stderr)
        safe = str(error) if isinstance(error, (ReleaseError, SymbolError)) else type(error).__name__
        print("Sentry release failed: " + safe, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
