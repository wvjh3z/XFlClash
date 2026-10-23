"""Validate the selected Android NDK and export its explicit CI environment."""
from pathlib import Path
import argparse
import json
import os
import re

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / 'tool/native_toolchain.json').read_text(encoding='utf-8'))['android_ndk']


def validate_ndk(value):
    if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 for c in value):
        raise ValueError('Explicit Android NDK path is required')
    root = Path(value).resolve(strict=True)
    if any(ord(c) < 32 for c in str(root)):
        raise ValueError('Unsafe Android NDK path')
    properties = (root / 'source.properties').read_text(encoding='utf-8')
    revision = re.search(r'^Pkg.Revision\s*=\s*(\S+)\s*$', properties, re.M)
    if not revision or revision[1] != PIN:
        raise ValueError('Android NDK version differs from the pinned release toolchain')
    if not (root / 'toolchains/llvm/prebuilt').is_dir():
        raise ValueError('Android NDK LLVM toolchain is missing')
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--path', required=True)
    parser.add_argument('--github-env', action='store_true')
    args = parser.parse_args()
    root = validate_ndk(args.path)
    if args.github_env:
        output = os.environ.get('GITHUB_ENV')
        if not output:
            raise ValueError('GITHUB_ENV is required')
        with Path(output).open('a', encoding='utf-8', newline='\n') as stream:
            for name in ('ANDROID_NDK', 'ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT'):
                stream.write(f'{name}={root}\n')
    print('Pinned Android NDK verified: ' + PIN)


if __name__ == '__main__':
    main()
