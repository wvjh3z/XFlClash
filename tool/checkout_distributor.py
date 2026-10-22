#!/usr/bin/env python3
"""Obtain the unchanged pinned packaging dependency without a client gitlink."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
from pub_get_retry import clean_environment, execute
from prepare_linux_packager import PINNED_REVISION

URL = 'https://github.com/chen08209/flutter_distributor.git'
RELATIVE = Path('.local-build/tool-sources/flutter_distributor') / PINNED_REVISION


def ensure_checkout(root: Path, *, url=URL, revision=PINNED_REVISION):
    if not re.fullmatch('[a-f0-9]{40}', revision):
        raise RuntimeError('Invalid immutable distributor revision')
    target = root / RELATIVE
    if target.is_symlink():
        raise RuntimeError('Distributor checkout must not be a symlink')
    environment = clean_environment(dict(os.environ))
    def git(at, *args):
        return subprocess.check_output(['git', '-c', 'credential.helper=', '-C', str(at), *args],
                                       env=environment, stderr=subprocess.PIPE, timeout=60).decode('utf-8').strip()
    def verify(at):
        if git(at, 'rev-parse', 'HEAD') != revision:
            raise RuntimeError('Pinned distributor checkout revision differs')
        if git(at, 'status', '--porcelain', '--untracked-files=no'):
            raise RuntimeError('Pinned distributor source is modified')
    if target.exists():
        verify(target)
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.checkout-', dir=target.parent) as temporary:
        staged = Path(temporary) / 'source'
        staged.mkdir()
        git(staged, 'init', '--quiet', '--template=')
        git(staged, 'config', 'core.longpaths', 'true')
        git(staged, 'config', 'core.autocrlf', 'false')
        git(staged, 'remote', 'add', 'origin', url)
        code, _ = execute(['git', '-c', 'credential.helper=', 'fetch', '--depth=1', 'origin', revision],
                          staged, environment, attempt_timeout=180, total_timeout=600)
        if code:
            raise RuntimeError('Pinned distributor fetch failed')
        git(staged, 'checkout', '--quiet', '--detach', revision)
        verify(staged)
        if target.exists():
            verify(target)  # Another preparation won; never overwrite it.
        else:
            staged.rename(target)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        ensure_checkout(args.project_root.resolve())
        print('Pinned distributor source ready: ' + PINNED_REVISION)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, 'Distributor checkout failed: ' + type(error).__name__ + '\n')


if __name__ == '__main__': main()
