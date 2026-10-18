#!/usr/bin/env python3
"""Pinned actionlint + ShellCheck. Authoring gate on Linux x64, no client build."""
from __future__ import annotations
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def verified_binary(archive, expected_sha, name):
    if hashlib.sha256(archive).hexdigest() != expected_sha:
        raise ValueError('lint_archive_hash_mismatch')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        members = [m for m in tar.getmembers() if Path(m.name).name == name]
        if len(members) != 1 or not members[0].isfile() or not 0 < members[0].size < 30_000_000:
            raise ValueError('invalid_lint_archive')
        return tar.extractfile(members[0]).read()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true', help='Download pinned archives if absent')
    args = parser.parse_args(argv)
    try:
        if platform.system() != 'Linux' or platform.machine().lower() not in ('x86_64','amd64'):
            raise ValueError('run_lints_on_Linux_x64_or_WSL')
        pins = json.loads((ROOT/'tool/build-tools.json').read_text(encoding='utf-8'))['lint_tools']
        if set(pins) != {'actionlint','shellcheck'} or any(not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',p['version']) or not re.fullmatch(r'[a-f0-9]{64}',p['sha256']) or not p['url'].startswith('https://github.com/') for p in pins.values()):
            raise ValueError('invalid_lint_pins')
        base = ROOT/'.local-build/lint-tools'
        base.mkdir(parents=True,exist_ok=True)
        for name,pin in pins.items():
            archive = base/(name+'-'+pin['version']+'.tar.gz')
            if not archive.exists():
                if not args.prepare:
                    raise ValueError('pinned_linter_missing_use_prepare')
                req = urllib.request.Request(pin['url'],headers={'User-Agent':'XFlclash-static-preflight'})
                with urllib.request.urlopen(req,timeout=60) as response:
                    raw = response.read(30_000_001)
                if len(raw) > 30_000_000:
                    raise ValueError('lint_download_too_large')
                binary = verified_binary(raw,pin['sha256'],name)
                archive.write_bytes(raw)
            else:
                binary = verified_binary(archive.read_bytes(),pin['sha256'],name)
            executable = base/name
            if executable.is_symlink(): raise ValueError('lint_binary_symlink')
            executable.write_bytes(binary)
            executable.chmod(0o755)
        env = {**os.environ, 'PATH': str(base)+os.pathsep+os.environ.get('PATH','')}
        result = subprocess.run([str(base/'actionlint'), '-shellcheck='+str(base/'shellcheck'), '-pyflakes=',
                                 *[str(p.relative_to(ROOT)) for p in sorted((ROOT/'.github/workflows').glob('*.yml'))]],
                                cwd=ROOT,env=env,timeout=90)
        shell = subprocess.run([str(base/'shellcheck'), '--shell=bash', '--severity=warning',
                                'scripts/package_desktop_local.sh'],cwd=ROOT,env=env,timeout=30)
        passed = result.returncode == 0 and shell.returncode == 0
        if passed: print('Static checks passed: '+', '.join(n+' '+p['version'] for n,p in pins.items()))
        return 0 if passed else 1
    except (OSError,ValueError,tarfile.TarError,subprocess.TimeoutExpired) as error:
        print('Static tooling failed: '+type(error).__name__,file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
