#!/usr/bin/env python3
"""Checkout the fixed private SDK without persisting its read credential.

Only clone/fetch receive a repository-scoped Authorization header through Git's
per-process configuration environment. Helpers, inherited Git overrides, tracing
and interactive prompts are disabled. Child output is discarded, never relayed.
No credential/configuration file or workflow environment file is written here.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys


REPOSITORY = "https://github.com/wvjh3z/Xboard_sdk.git"
HEADER_KEY = "http." + REPOSITORY + ".extraheader"
TIMEOUTS = {"clone": 180, "fetch": 180, "checkout": 60}


class CheckoutError(Exception):
    def __init__(self, phase: str, code: str, exit_code: int | None = None):
        super().__init__(code)
        self.phase, self.code, self.exit_code = phase, code, exit_code


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise CheckoutError("arguments", "invalid_arguments")


def clean_environment(environment: dict[str, str]) -> dict[str, str]:
    result = {key: value for key, value in environment.items()
              if not key.upper().startswith(("GIT_", "SENTRY_"))
              and key.upper() not in ("SSH_ASKPASS", "SDK_REF")
              and not any(word in key.upper() for word in ("TOKEN", "PASSWORD", "SECRET", "DSN"))}
    result.update(GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="", SSH_ASKPASS="",
                  GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="")
    return result


def authentication_environment(environment: dict[str, str], token: str) -> dict[str, str]:
    result = clean_environment(environment)
    encoded = base64.b64encode(("x-access-token:" + token).encode("ascii")).decode("ascii")
    # Empty values reset inherited multi-valued headers/helpers. Scope the new
    # header to this repository rather than all github.com requests.
    result.update(GIT_CONFIG_COUNT="3", GIT_CONFIG_KEY_0=HEADER_KEY, GIT_CONFIG_VALUE_0="",
                  GIT_CONFIG_KEY_1=HEADER_KEY, GIT_CONFIG_VALUE_1="AUTHORIZATION: basic " + encoded,
                  GIT_CONFIG_KEY_2="credential.helper", GIT_CONFIG_VALUE_2="")
    return result


def terminate_tree(process, environment: dict[str, str]) -> None:
    if os.name == "nt":
        try:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           env=clean_environment(environment), stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass
        if process.poll() is None:
            process.kill()
    else:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            if sig == signal.SIGTERM:
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        raise CheckoutError("cleanup", "process_cleanup_failed") from None


def run_phase(arguments: list[str], phase: str, environment: dict[str, str], timeout: float) -> None:
    options = {"start_new_session": True} if os.name != "nt" else {
        "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW}
    try:
        process = subprocess.Popen(arguments, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **options)
    except OSError:
        raise CheckoutError(phase, "git_start_failed") from None
    try:
        code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate_tree(process, environment)
        raise CheckoutError(phase, "git_timeout") from None
    if code:
        raise CheckoutError(phase, "git_nonzero_exit", code)


def checkout(destination: Path, ref: str, environment: dict[str, str]) -> None:
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+/-]{0,199}", ref)
            or ".." in ref or "//" in ref or ref.endswith("/")):
        raise CheckoutError("preflight", "invalid_sdk_ref")
    workspace = Path(environment.get("GITHUB_WORKSPACE", str(Path.cwd()))).resolve()
    if not workspace.is_dir():
        raise CheckoutError("preflight", "workspace_unavailable")
    expected = workspace.parent / "Xboard_sdk"
    if destination.is_symlink() or destination.resolve() != expected.resolve():
        raise CheckoutError("preflight", "sdk_sibling_destination_required")
    if destination.exists():
        raise CheckoutError("preflight", "destination_exists")
    token = environment.get("SDK_READ_TOKEN", "")
    if not token or len(token) > 4096 or any(not 33 <= ord(character) <= 126 for character in token):
        raise CheckoutError("preflight", "sdk_read_token_required_or_invalid")
    git = shutil.which("git", path=environment.get("PATH"))
    if not git:
        raise CheckoutError("preflight", "git_unavailable")
    private = authentication_environment(environment, token)
    public = clean_environment(environment)
    commands = (
        ("clone", [git, "clone", "--no-checkout", "--depth", "1", REPOSITORY, str(destination)], private),
        ("fetch", [git, "-C", str(destination), "fetch", "--depth", "1", "origin", ref], private),
        ("checkout", [git, "-C", str(destination), "checkout", "--detach", "FETCH_HEAD"], public),
    )
    for phase, arguments, child_environment in commands:
        run_phase(arguments, phase, child_environment, TIMEOUTS[phase])


def main(argv=None, *, environment=None) -> int:
    parser = SafeArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--ref", required=True)
    try:
        args = parser.parse_args(argv)
        checkout(args.destination, args.ref, dict(os.environ) if environment is None else dict(environment))
    except CheckoutError as error:
        report = {"status": "failed", "phase": error.phase, "code": error.code}
        if error.exit_code is not None:
            report["exit_code"] = error.exit_code
        print(json.dumps(report), file=sys.stderr)
        return 1
    except (OSError, ValueError):
        print(json.dumps({"status": "failed", "phase": "preflight", "code": "checkout_io_failed"}), file=sys.stderr)
        return 1
    print(json.dumps({"status": "complete", "credential_persisted": False}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
