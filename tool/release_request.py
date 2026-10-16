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
EVENT_TYPE = "xflclash_numbered_release_v1"
TARGETS = ("android", "windows-amd64", "linux-amd64", "linux-arm64", "macos-amd64", "macos-arm64",
           "desktop", "desktop-except-linux-amd64", "all")
FLAVORS = ("brand_a", "brand_b")
MAX_BUILD_NUMBER = 65_535
PUBLIC_KEYS = {"flavor", "target", "build_number", "upload"}


class RequestError(ValueError):
    pass


def identity_number(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", value):
        raise RequestError("Invalid release run identity")
    return value


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


def validate_origin(value):
    if not isinstance(value, dict) or set(value) != {"run_id", "run_number", "sha", "ref"}:
        raise RequestError("Invalid release preparation metadata")
    return {"run_id": identity_number(value["run_id"]),
            "run_number": identity_number(value["run_number"]),
            "sha": source_sha(value["sha"]), "ref": source_ref(value["ref"])}


def source_identity(env):
    return validate_origin({"run_id": env.get("GITHUB_RUN_ID", ""),
                            "run_number": env.get("GITHUB_RUN_NUMBER", ""),
                            "sha": env.get("GITHUB_SHA", ""), "ref": env.get("GITHUB_REF", "")})


def requested_number(value, *, required=False):
    if value == "" and not required:
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
    kind = env.get("GITHUB_EVENT_NAME")
    if kind == "workflow_dispatch":
        values = event.get("inputs")
        if not isinstance(values, dict) or set(values) != PUBLIC_KEYS:
            raise RequestError("Public release requests require exactly four configured inputs")
        origin = None
        actual = source_identity(env)
    elif kind == "repository_dispatch":
        if event.get("action") != EVENT_TYPE:
            raise RequestError("Unsupported internal release event")
        values = event.get("client_payload")
        if not isinstance(values, dict) or set(values) != PUBLIC_KEYS | {"origin"}:
            raise RequestError("Invalid internal release payload")
        origin = validate_origin(values["origin"])
        if origin["run_id"] == identity_number(env.get("GITHUB_RUN_ID", "")):
            raise RequestError("A preparation cannot be its own numbered build")
        actual = origin
    else:
        raise RequestError("Unsupported release event")
    flavor, target = values["flavor"], values["target"]
    if flavor not in FLAVORS or target not in TARGETS:
        raise RequestError("Invalid release brand or target")
    number = requested_number(values["build_number"], required=origin is not None)
    upload = values["upload"]
    if kind == "workflow_dispatch" and isinstance(upload, str) and upload in ("true", "false"):
        upload = upload == "true"
    if type(upload) is not bool:
        raise RequestError("Invalid release upload option")
    return {"flavor": flavor, "target": target, "requested_number": number,
            "upload": "true" if upload else "false", "source_sha": actual["sha"],
            "source_ref": actual["ref"],
            "prepared_from": json.dumps(origin, sort_keys=True, separators=(",", ":")) if origin else "",
            "is_preparation": "true" if kind == "workflow_dispatch" and not number else "false"}


def check_source_checkout(root, expected):
    expected = source_sha(expected)
    try:
        result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True,
                                capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise RequestError("Release source checkout is unavailable") from None
    if result.stdout.strip() != expected:
        raise RequestError("Release source checkout differs from the prepared snapshot")


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
    except (RequestError, OSError, KeyError):
        print("Release request: invalid event, policy, source snapshot or Actions output", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
