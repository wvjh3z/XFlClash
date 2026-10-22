#!/usr/bin/env python3
"""Run Flutter unit/widget checks without compiling native application assets."""
from contextlib import contextmanager
from pathlib import Path
import re
import subprocess
import sys


@contextmanager
def without_native_builds(path):
    original = path.read_bytes()
    pattern = rb'(?m)^(    (?:setup|rust_api):\r?\n      build_assets: )true(\r?)$'
    updated, count = re.subn(pattern, rb'\1false\2', original)
    if count != 2: raise RuntimeError('Expected two enabled native build hooks')
    path.write_bytes(updated)
    try:
        yield
    finally:
        if path.read_bytes() != updated:
            raise RuntimeError('Pubspec changed during checks; refusing to overwrite it')
        path.write_bytes(original)


def main():
    if not sys.argv[1:]: raise SystemExit('Pass Flutter test paths/options')
    with without_native_builds(Path('pubspec.yaml')):
        return subprocess.run(['flutter','test',*sys.argv[1:]]).returncode


if __name__ == '__main__': raise SystemExit(main())
