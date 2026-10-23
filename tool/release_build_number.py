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
import subprocess
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


def publish(root: Path, flavor: str, ref: str, source: str, built: str) -> None:
    """Advance only the built branch, using a bounded compare-and-swap push.

    Run from the disposable CI checkout, with this script copied outside it.
    A lease also prevents recreating a branch deleted between fetch and push.
    Every proposed commit has the fetched tip as its sole parent: the lease
    never permits a history rewrite, even though Git calls it force-with-lease.
    """
    if (flavor not in FLAVORS or not isinstance(ref, str) or len(ref) > 1024
            or not ref.startswith('refs/heads/')
            or any(ord(c) < 32 or ord(c) == 127 for c in ref)
            or not re.fullmatch(r'[a-f0-9]{40}', source)):
        raise BuildNumberError('Publication requires the original branch and source SHA')
    integer(built)

    def git(*args, check=True):
        result = subprocess.run(['git', *args], cwd=root, capture_output=True,
                                text=True, encoding='utf-8', errors='replace', timeout=60)
        if check and result.returncode:
            raise BuildNumberError('Number publication Git operation failed: ' + args[0])
        return result

    git('check-ref-format', ref)
    if git('rev-parse', 'HEAD').stdout.strip() != source:
        raise BuildNumberError('Number publication checkout differs from built source')
    if git('status', '--porcelain', '--untracked-files=normal').stdout.strip():
        raise BuildNumberError('Number publication requires a clean temporary checkout')
    relative = f'scripts/build_number.{flavor}.txt'
    for attempt in range(1, 4):
        git('fetch', '--no-tags', 'origin', ref)
        tip = git('rev-parse', '--verify', 'FETCH_HEAD^{commit}').stdout.strip()
        if git('merge-base', '--is-ancestor', source, tip, check=False).returncode:
            raise BuildNumberError('Source branch no longer contains the built commit')
        git('reset', '--hard', tip)
        counter = root / relative
        if counter.is_symlink() or counter.parent.is_symlink() or not counter.is_file():
            raise BuildNumberError('Source branch counter is missing or unsafe')
        current = counter.read_text(encoding='utf-8').strip()
        number = next_counter(current, built)
        if number == integer(current, maximum=MAX_BUILD_NUMBER + 1):
            print(f'Next {flavor} number already sufficient on {ref}: {number}')
            return
        counter.write_text(str(number) + '\n', encoding='utf-8')
        git('add', '--', relative)
        git('-c', 'user.name=anonymous', '-c', 'user.email=anonymous@users.noreply.github.com',
            'commit', '-m', f'[xfork] chore(build): {flavor} next build {number}')
        commit = git('rev-parse', 'HEAD').stdout.strip()
        if git('rev-list', '--parents', '-n', '1', commit).stdout.split() != [commit, tip]:
            raise BuildNumberError('Counter commit must directly extend the fetched branch')
        pushed = git('push', f'--force-with-lease={ref}:{tip}', 'origin', f'{commit}:{ref}', check=False)
        if pushed.returncode == 0:
            print(f'Published next {flavor} number to {ref}: {number}')
            return
        print(f'Counter push not accepted ({attempt}/3)')
    raise BuildNumberError('Counter push failed after three attempts')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("resolve", "advance", "publish"))
    parser.add_argument("--flavor", required=True, choices=FLAVORS)
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    counter = args.project_root / f"scripts/build_number.{args.flavor}.txt"
    try:
        if args.action == 'publish':
            publish(args.project_root.resolve(), args.flavor,
                    os.environ.get('BUILD_SOURCE_REF', ''), os.environ.get('BUILD_SOURCE_SHA', ''),
                    os.environ.get('RESOLVED_BUILD_NUMBER', ''))
            return 0
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
    except (OSError, KeyError, UnicodeError, subprocess.SubprocessError):
        print("Build number: counter or Actions output is unavailable", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
