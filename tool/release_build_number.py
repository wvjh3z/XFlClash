#!/usr/bin/env python3
"""Validate release numbers and advance the source counter.

Numbers are source-snapshot counters, not globally reserved allocations. Values
enter through environment variables or structured JSON, never shell source.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys

MAX_BUILD_NUMBER = 65_535
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("resolve", "advance"))
    parser.add_argument("--flavor", required=True, choices=FLAVORS)
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    counter = args.project_root / f"scripts/build_number.{args.flavor}.txt"
    try:
        current = counter.read_text(encoding="utf-8").strip()
        if args.action == "advance":
            number = next_counter(current, os.environ.get("RESOLVED_BUILD_NUMBER", ""))
            counter.write_text(str(number) + "\n", encoding="utf-8")
            print(f"Next {args.flavor} build number: {number}")
        else:
            import release_request as requests
            requested = os.environ.get("REQUESTED_BUILD_NUMBER", "")
            if "BUILD_SOURCE_SHA" in os.environ:
                requests.check_source_checkout(args.project_root, os.environ["BUILD_SOURCE_SHA"])
                requests.source_ref(os.environ.get("BUILD_SOURCE_REF", ""))
            number = resolve(current, requested)
            with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                output.write(f"build_number={number}\n")
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as summary:
                source = "manual input" if requested else "source snapshot counter"
                summary.write(f"## Build {number}\n\nBrand: `{args.flavor}`\n\n"
                              f"Number source: {source}. All targets in this run use **{number}**.\n")
                if "BUILD_SOURCE_SHA" in os.environ:
                    summary.write(f"\nSource: `{os.environ['BUILD_SOURCE_SHA']}` (`{os.environ['BUILD_SOURCE_REF']}`).\n")
            print(f"Using {args.flavor} build {number}")
        return 0
    except ValueError as error:
        print("Build number: " + str(error), file=sys.stderr)
    except (OSError, KeyError, UnicodeError):
        print("Build number: counter or Actions output is unavailable", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
