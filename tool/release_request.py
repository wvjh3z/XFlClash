#!/usr/bin/env python3
"""Normalize public release requests and read policy from the pinned source."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPOSITORY = "wvjh3z/XFlClash"
TARGETS = ("android", "windows-amd64", "linux-amd64", "linux-arm64", "macos-amd64", "macos-arm64",
           "desktop", "desktop-except-linux-amd64", "all")
FLAVORS = ("brand_a", "brand_b")
MAX_BUILD_NUMBER = 65_535
PUBLIC_DEFAULTS = {"flavor": "brand_a", "target": "android", "build_number": "", "upload": False}


class RequestError(ValueError):
    pass


def source_sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{40}", value):
        raise RequestError("Invalid release source SHA")
    return value


def source_ref(value):
    if (not isinstance(value, str) or len(value) > 1024
            or not value.startswith(("refs/heads/", "refs/tags/"))):
        raise RequestError("Release source requires a branch or tag reference")
    name = value.split("/", 2)[2]
    # Same ref constraints as git-check-ref-format, without invoking a shell.
    if (not name or name.startswith("/") or name.endswith(("/", ".")) or "//" in name
            or ".." in name or "@{" in name
            or any(ord(c) < 33 or ord(c) == 127 or c in "~^:?*[\\" for c in name)
            or any(part.startswith(".") or part.endswith(".lock") for part in name.split("/"))):
        raise RequestError("Invalid release source reference")
    return value


def requested_number(value):
    if value is None or value == "":
        return ""
    if (not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,4}", value)
            or int(value) > MAX_BUILD_NUMBER):
        raise RequestError("Build number must be an integer from 1 to 65535")
    return value


def normalize(event, env):
    if env.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise RequestError("Release requests are restricted to this repository")
    if not isinstance(event, dict):
        raise RequestError("Invalid release event")
    if env.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise RequestError("Unsupported release event")
    supplied = event.get("inputs", {})
    if not isinstance(supplied, dict) or set(supplied) - PUBLIC_DEFAULTS.keys():
        raise RequestError("Invalid public release input fields")
    values = {**PUBLIC_DEFAULTS, **supplied}
    flavor, target = values["flavor"], values["target"]
    if flavor not in FLAVORS or target not in TARGETS:
        raise RequestError("Invalid release brand or target")
    number = requested_number(values["build_number"])
    upload = values["upload"]
    if isinstance(upload, str) and upload in ("true", "false"):
        upload = upload == "true"
    if type(upload) is not bool:
        raise RequestError("Invalid release upload option")
    return {"flavor": flavor, "target": target, "requested_number": number,
            "upload": "true" if upload else "false", "source_sha": source_sha(env.get("GITHUB_SHA", "")),
            "source_ref": source_ref(env.get("GITHUB_REF", ""))}


def check_source_checkout(root, expected):
    expected = source_sha(expected)
    try:
        result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True,
                                capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise RequestError("Release source checkout is unavailable") from None
    if result.stdout.strip() != expected:
        raise RequestError("Release source checkout differs from the requested snapshot")


def read_json(path):
    try:
        with Path(path).open("rb") as source:
            data = source.read(65537)
        if len(data) > 65536:
            raise ValueError()
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError()
                result[key] = value
            return result
        return json.loads(data, object_pairs_hook=unique_object)
    except (OSError, ValueError, UnicodeError, TypeError):
        raise RequestError("Release JSON configuration or event is unavailable or invalid") from None


def config(root, env):
    check_source_checkout(root, env.get("BUILD_SOURCE_SHA", ""))
    values = read_json(root / "tool/release-config.json")
    if not isinstance(values, dict) or set(values) != {"sdk_ref", "verify_symbolication"}:
        raise RequestError("Invalid release configuration schema")
    sdk = values["sdk_ref"]
    if not isinstance(sdk, str):
        raise RequestError("Release SDK requires a fixed commit or explicit tag")
    if not re.fullmatch(r"[a-f0-9]{40}", sdk):
        if not sdk.startswith("refs/tags/"):
            raise RequestError("Release SDK requires a fixed commit or explicit tag")
        source_ref(sdk)
    if type(values["verify_symbolication"]) is not bool:
        raise RequestError("Invalid release symbolication policy")
    return {"sdk_ref": sdk, "verify_symbolication": "true" if values["verify_symbolication"] else "false"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("normalize", "config"))
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    try:
        values = (normalize(read_json(os.environ["GITHUB_EVENT_PATH"]), os.environ)
                  if args.action == "normalize" else config(args.project_root, os.environ))
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
        print("Release request validated" if args.action == "normalize" else "Pinned release configuration validated")
        return 0
    except RequestError as error:
        print("Release request: " + str(error), file=sys.stderr)
        return 1
    except (OSError, KeyError):
        print("Release request: event or Actions output is unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
