#!/usr/bin/env python3
"""Validate a GitHub build number and advance its next-number counter.

This does not allocate numbers across machines. Local Android remains unchanged.
All values enter through environment variables/arguments, never shell source.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

# windows/runner/Runner.rc uses the build number as a 16-bit FILEVERSION part.
# A shared multi-platform input must fit that target as well as Android.
MAX_BUILD_NUMBER = 65_535
REPOSITORY = "wvjh3z/XFlClash"
DISPATCH_URL = f"https://api.github.com/repos/{REPOSITORY}/actions/workflows/release-package.yml/dispatches"
TARGETS = ("android", "windows-amd64", "linux-amd64", "linux-arm64", "macos-amd64", "macos-arm64",
           "desktop", "desktop-except-linux-amd64", "all")


class BuildNumberError(ValueError):
    pass


def integer(value: str, *, maximum=MAX_BUILD_NUMBER) -> int:
    if not re.fullmatch(r"[1-9][0-9]{0,9}", value) or int(value) > maximum:
        raise BuildNumberError(f"Build number must be an integer from 1 to {maximum}")
    return int(value)


def resolve(current: str, requested: str = "") -> int:
    available = integer(current)
    number = integer(requested) if requested else available
    if number < available:
        raise BuildNumberError("Requested build number is below the counter in this source snapshot")
    return number


def next_counter(current: str, built: str) -> int:
    # MAX + 1 is a valid exhausted counter, but cannot be used for a new build.
    return max(integer(current, maximum=MAX_BUILD_NUMBER + 1), integer(built) + 1)


def run_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", value):
        raise BuildNumberError("Invalid preparation run identity")
    return value


def source_identity(env):
    sha, ref = env.get("GITHUB_SHA", ""), env.get("GITHUB_REF", "")
    if not re.fullmatch(r"[a-f0-9]{40}", sha):
        raise BuildNumberError("Invalid preparation source identity")
    if (not ref.startswith(("refs/heads/", "refs/tags/")) or len(ref) > 1024
            or any(ord(c) < 33 or c in "~^:?*[\\" for c in ref)):
        raise BuildNumberError("Preparation requires a branch or tag reference")
    return {"run_id": run_id(env.get("GITHUB_RUN_ID", "")), "sha": sha, "ref": ref}


def check_prepared_input(env, requested):
    """A child run must use exactly the source/ref that prepared its number."""
    raw = env.get("PREPARED_FROM", "")
    if not raw:
        return None
    try:
        if len(raw) > 2048:
            raise ValueError()
        parent = json.loads(raw)
        if not isinstance(parent, dict) or set(parent) != {"run_id", "sha", "ref"}:
            raise ValueError()
        run_id(parent["run_id"])
        actual = source_identity(env)
        if not requested or parent["run_id"] == actual["run_id"]:
            raise ValueError()
        if parent["sha"] != actual["sha"] or parent["ref"] != actual["ref"]:
            raise BuildNumberError("Prepared source changed; start a new Run workflow instead of building with stale inputs")
        return parent
    except (ValueError, TypeError, KeyError) as error:
        if isinstance(error, BuildNumberError):
            raise
        raise BuildNumberError("Invalid preparation metadata; numbered child input is required") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def send_dispatch(payload, token):
    """One POST only. A lost response may still have created the child run."""
    if not token or len(token) > 4096 or any(not 33 <= ord(c) <= 126 for c in token):
        raise BuildNumberError("Workflow dispatch token is unavailable")
    request = urllib.request.Request(DISPATCH_URL, method="POST", data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json", "X-GitHub-Api-Version": "2022-11-28",
                 "User-Agent": "XFlClash-numbered-build"})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            status, raw = response.status, response.read(65537)
        if status != 200 or len(raw) > 65536:
            raise ValueError()
        result = json.loads(raw)
        child = result.get("workflow_run_id")
        if type(child) is not int or not 0 < child < 10**20:
            raise ValueError()
        html = f"https://github.com/{REPOSITORY}/actions/runs/{child}"
        api = f"https://api.github.com/repos/{REPOSITORY}/actions/runs/{child}"
        if result.get("html_url") != html or result.get("run_url") != api:
            raise ValueError()
        return {"run_id": child, "html_url": html}
    except urllib.error.HTTPError as error:
        raise BuildNumberError(f"Workflow dispatch HTTP {error.code}; check Actions before starting another preparation") from None
    except (OSError, ValueError, TypeError, AttributeError):
        raise BuildNumberError("Workflow dispatch not confirmed; check Actions before retrying to avoid duplicate builds") from None


def dispatch_numbered_build(flavor, env):
    if env.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise BuildNumberError("Workflow dispatch is restricted to this repository")
    if env.get("REQUESTED_BUILD_NUMBER") or env.get("PREPARED_FROM"):
        raise BuildNumberError("Only a fresh automatic preparation may dispatch a numbered build")
    if env.get("GITHUB_RUN_ATTEMPT") != "1":
        raise BuildNumberError("Do not rerun preparation; open its numbered build or start a new Run workflow")
    parent = source_identity(env)
    number = integer(env.get("RESOLVED_BUILD_NUMBER", ""))
    target, sdk = env.get("BUILD_TARGET", ""), env.get("SDK_REF", "")
    if (target not in TARGETS or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+/-]{0,199}", sdk)
            or ".." in sdk or "//" in sdk or sdk.endswith("/")):
        raise BuildNumberError("Invalid numbered build inputs")
    flags = [env.get(name, "") for name in ("UPLOAD_PACKAGES", "VERIFY_SYMBOLICATION")]
    if any(value not in ("true", "false") for value in flags):
        raise BuildNumberError("Invalid numbered build options")
    reference = parent["ref"].split("/", 2)[2]
    payload = {"ref": reference, "return_run_details": True, "inputs": {
        "flavor": flavor, "target": target, "build_number": str(number), "sdk_ref": sdk,
        "upload": flags[0] == "true", "verify_symbolication": flags[1] == "true",
        "prepared_from": json.dumps(parent, sort_keys=True, separators=(",", ":"))}}
    # Validate Actions output paths before the side effect; never retry this POST.
    output, summary = Path(env["GITHUB_OUTPUT"]), Path(env["GITHUB_STEP_SUMMARY"])
    if not output.is_file() or not summary.is_file():
        raise BuildNumberError("Actions output paths are unavailable")
    result = send_dispatch(payload, env.get("BUILD_DISPATCH_TOKEN", ""))
    print(f"Started build {number}: {result['html_url']}", flush=True)
    with output.open("a", encoding="utf-8") as out:
        out.write(f"numbered_run_id={result['run_id']}\nnumbered_run_url={result['html_url']}\n")
    with summary.open("a", encoding="utf-8") as out:
        out.write(f"\n## 正式构建 {number}\n\n[打开带编号的正式构建]({result['html_url']})\n\n"
                  "本记录只准备编号并发起正式构建；实际成功/失败以正式记录为准。\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("resolve", "advance", "dispatch"))
    parser.add_argument("--flavor", required=True, choices=("brand_a", "brand_b"))
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    counter = args.project_root / f"scripts/build_number.{args.flavor}.txt"
    try:
        if args.action == "dispatch":
            dispatch_numbered_build(args.flavor, dict(os.environ))
            return 0
        current = counter.read_text(encoding="utf-8").strip()
        if args.action == "advance":
            number = next_counter(current, os.environ.get("RESOLVED_BUILD_NUMBER", ""))
            counter.write_text(str(number) + "\n", encoding="utf-8")
            print(f"Next {args.flavor} build number: {number}")
        else:
            requested = os.environ.get("REQUESTED_BUILD_NUMBER", "")
            parent = check_prepared_input(os.environ, requested)
            number = resolve(current, requested)
            with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                output.write(f"build_number={number}\n")
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as summary:
                source = "automatic preparation" if parent else "manual input" if requested else "source snapshot counter"
                summary.write(f"## Build {number}\n\nBrand: `{args.flavor}`\n\n"
                              f"Number source: {source}. All targets in this run use **{number}**.\n")
                if parent:
                    summary.write(f"\n[Preparation run](https://github.com/{REPOSITORY}/actions/runs/{parent['run_id']})\n")
            print(f"Using {args.flavor} build {number}")
        return 0
    except BuildNumberError as error:
        print("Build number: " + str(error), file=sys.stderr)
    except (OSError, KeyError, UnicodeError):
        print("Build number: counter or Actions output is unavailable", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
