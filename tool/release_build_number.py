#!/usr/bin/env python3
"""Validate release numbers, dispatch numbered runs and advance the source counter.

Numbers are source-snapshot counters, not globally reserved allocations. Values
enter through environment variables or structured JSON, never shell source.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request

MAX_BUILD_NUMBER = 65_535
REPOSITORY = "wvjh3z/XFlClash"
EVENT_TYPE = "xflclash_numbered_release_v1"
DISPATCH_URL = f"https://api.github.com/repos/{REPOSITORY}/dispatches"
WORKFLOW_RUNS_URL = f"https://api.github.com/repos/{REPOSITORY}/actions/workflows/release-package.yml/runs"
WORKFLOW_URL = f"https://github.com/{REPOSITORY}/actions/workflows/release-package.yml"
TARGETS = ("android", "windows-amd64", "linux-amd64", "linux-arm64", "macos-amd64", "macos-arm64",
           "desktop", "desktop-except-linux-amd64", "all")
FLAVORS = ("brand_a", "brand_b")


class BuildNumberError(ValueError):
    pass


def integer(value: str, *, maximum=MAX_BUILD_NUMBER) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", value) or int(value) > maximum:
        raise BuildNumberError(f"Build number must be an integer from 1 to {maximum}")
    return int(value)


def resolve(current: str, requested: str = "") -> int:
    available = integer(current)
    number = integer(requested) if requested else available
    if number < available:
        raise BuildNumberError("Requested build number is below the counter in this source snapshot")
    return number


def next_counter(current: str, built: str) -> int:
    return max(integer(current, maximum=MAX_BUILD_NUMBER + 1), integer(built) + 1)


def source_identity(env):
    import release_request as requests
    try:
        return requests.source_identity(env)
    except requests.RequestError as error:
        raise BuildNumberError(str(error)) from None


def check_prepared_input(env, requested):
    """Internal runs build the original SHA, independent of default-branch events."""
    import release_request as requests
    raw = env.get("PREPARED_FROM", "")
    if not raw:
        if env.get("GITHUB_EVENT_NAME") == "repository_dispatch":
            raise BuildNumberError("Internal release requires preparation metadata")
        return None
    try:
        if len(raw) > 2048:
            raise ValueError()
        parent = requests.validate_origin(json.loads(raw))
        if (not requested or parent["run_id"] == requests.identity_number(env.get("GITHUB_RUN_ID", ""))
                or env.get("GITHUB_EVENT_NAME") != "repository_dispatch"):
            raise ValueError()
        sha = requests.source_sha(env.get("BUILD_SOURCE_SHA", ""))
        ref = requests.source_ref(env.get("BUILD_SOURCE_REF", ""))
        if parent["sha"] != sha or parent["ref"] != ref:
            raise BuildNumberError("Prepared source changed; start a new Run workflow")
        return parent
    except (ValueError, TypeError, KeyError) as error:
        if isinstance(error, BuildNumberError):
            raise
        raise BuildNumberError("Invalid preparation metadata; numbered internal input is required") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def token_headers(token):
    if not token or len(token) > 4096 or any(not 33 <= ord(c) <= 126 for c in token):
        raise BuildNumberError("Release dispatch token is unavailable")
    return {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
            "Content-Type": "application/json", "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "XFlClash-numbered-build"}


def send_dispatch(payload, token):
    """One POST only. A lost response may still have created the child run."""
    request = urllib.request.Request(DISPATCH_URL, method="POST", data=json.dumps(payload).encode(),
                                     headers=token_headers(token))
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            status, raw = response.status, response.read(1)
        if status != 204 or raw:
            raise ValueError()
    except urllib.error.HTTPError as error:
        raise BuildNumberError(f"Release dispatch HTTP {error.code}; check Actions before starting another preparation") from None
    except (OSError, ValueError, TypeError, AttributeError):
        raise BuildNumberError("Release dispatch not confirmed; check Actions before retrying to avoid duplicate builds") from None


def numbered_title(flavor, target, number, origin):
    return f"{flavor} · {target} · build {number} · 准备 #{origin['run_number']}"


def find_numbered_build(title, token):
    """Best-effort bounded read-only discovery; never repeat the dispatch POST."""
    headers = token_headers(token)
    deadline = time.monotonic() + 12
    for _ in range(3):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        request = urllib.request.Request(WORKFLOW_RUNS_URL + "?event=repository_dispatch&per_page=100",
                                         headers=headers, method="GET")
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=min(4, remaining)) as response:
                status, raw = response.status, response.read(1_048_577)
            if status != 200 or len(raw) > 1_048_576:
                return None
            result = json.loads(raw)
            if not isinstance(result, dict) or not isinstance(result.get("workflow_runs"), list):
                return None
            matches = [run for run in result["workflow_runs"]
                       if isinstance(run, dict) and run.get("event") == "repository_dispatch"
                       and run.get("display_title") == title]
            if len(matches) > 1:
                return None
            if len(matches) == 1:
                run = matches[0]
                child = run.get("id")
                if type(child) is not int or not 0 < child < 10**20:
                    return None
                html = f"https://github.com/{REPOSITORY}/actions/runs/{child}"
                api = f"https://api.github.com/repos/{REPOSITORY}/actions/runs/{child}"
                if (run.get("html_url") != html or run.get("url") != api
                        or run.get("path", "").split("@", 1)[0] != ".github/workflows/release-package.yml"):
                    return None
                return {"run_id": child, "html_url": html}
        except (OSError, ValueError, TypeError, AttributeError):
            # GETs may be retried; a successful POST is never repeated.
            continue
    return None


def dispatch_numbered_build(flavor, env):
    import release_request as requests
    if env.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise BuildNumberError("Release dispatch is restricted to this repository")
    if (env.get("GITHUB_EVENT_NAME") != "workflow_dispatch" or env.get("REQUESTED_BUILD_NUMBER")
            or env.get("PREPARED_FROM")):
        raise BuildNumberError("Only a fresh automatic preparation may dispatch a numbered build")
    if env.get("GITHUB_RUN_ATTEMPT") != "1":
        raise BuildNumberError("Do not rerun preparation; open its numbered build or start a new Run workflow")
    parent = source_identity(env)
    if (env.get("BUILD_SOURCE_SHA", parent["sha"]) != parent["sha"]
            or env.get("BUILD_SOURCE_REF", parent["ref"]) != parent["ref"]):
        raise BuildNumberError("Preparation source changed")
    number = integer(env.get("RESOLVED_BUILD_NUMBER", ""))
    target = env.get("BUILD_TARGET", "")
    if flavor not in requests.FLAVORS or target not in TARGETS:
        raise BuildNumberError("Invalid numbered build inputs")
    upload = env.get("UPLOAD_PACKAGES", "")
    if upload not in ("true", "false"):
        raise BuildNumberError("Invalid numbered build options")
    payload = {"event_type": EVENT_TYPE, "client_payload": {
        "flavor": flavor, "target": target, "build_number": str(number),
        "upload": upload == "true", "origin": parent}}
    output, summary = Path(env["GITHUB_OUTPUT"]), Path(env["GITHUB_STEP_SUMMARY"])
    if not output.is_file() or not summary.is_file():
        raise BuildNumberError("Actions output paths are unavailable")
    token = env.get("BUILD_DISPATCH_TOKEN", "")
    send_dispatch(payload, token)
    title = numbered_title(flavor, target, number, parent)
    result = find_numbered_build(title, token)
    with summary.open("a", encoding="utf-8") as out:
        out.write(f"\n## 正式构建 {number}\n\n")
        if result:
            print(f"Started build {number}: {result['html_url']}", flush=True)
            with output.open("a", encoding="utf-8") as values:
                values.write(f"numbered_run_id={result['run_id']}\nnumbered_run_url={result['html_url']}\n")
            out.write(f"[打开带编号的正式构建]({result['html_url']})\n\n")
        else:
            print("Release dispatch accepted; numbered run link is not yet confirmed. Check Actions before retrying.", flush=True)
            out.write(f"派发请求已受理，但尚未确认唯一的正式记录。[查看 Actions 列表]({WORKFLOW_URL})，"
                      f"查找标题 `{title}`。不要重跑准备阶段或重复派发。\n\n")
        out.write("本记录只准备编号并发起正式构建；实际成功/失败以正式记录为准。\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("resolve", "advance", "dispatch"))
    parser.add_argument("--flavor", required=True, choices=FLAVORS)
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
            import release_request as requests
            requested = os.environ.get("REQUESTED_BUILD_NUMBER", "")
            parent = check_prepared_input(os.environ, requested)
            if "BUILD_SOURCE_SHA" in os.environ:
                requests.check_source_checkout(args.project_root, os.environ["BUILD_SOURCE_SHA"])
                requests.source_ref(os.environ.get("BUILD_SOURCE_REF", ""))
            number = resolve(current, requested)
            with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                output.write(f"build_number={number}\n")
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as summary:
                source = "automatic preparation" if parent else "manual input" if requested else "source snapshot counter"
                summary.write(f"## Build {number}\n\nBrand: `{args.flavor}`\n\n"
                              f"Number source: {source}. All targets in this run use **{number}**.\n")
                if "BUILD_SOURCE_SHA" in os.environ:
                    summary.write(f"\nSource: `{os.environ['BUILD_SOURCE_SHA']}` (`{os.environ['BUILD_SOURCE_REF']}`).\n")
                if parent:
                    summary.write(f"\n[Preparation run #{parent['run_number']}](https://github.com/{REPOSITORY}/actions/runs/{parent['run_id']})\n")
            print(f"Using {args.flavor} build {number}")
        return 0
    except ValueError as error:
        print("Build number: " + str(error), file=sys.stderr)
    except (OSError, KeyError, UnicodeError):
        print("Build number: counter or Actions output is unavailable", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
