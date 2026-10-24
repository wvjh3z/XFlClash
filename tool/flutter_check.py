#!/usr/bin/env python3
"""Run Flutter unit/widget checks without compiling native application assets."""
from contextlib import contextmanager
from pathlib import Path
import re
import os
import shutil
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


def command(arguments, *, environment=None, windows=None):
    environment = os.environ if environment is None else environment
    windows = os.name == 'nt' if windows is None else windows
    if windows:
        # Run the same prepared Flutter tool using an executable, not a .bat
        # interpreted by cmd.exe. Keep Unicode, spaces and metacharacters as argv.
        root = environment.get('FLUTTER_ROOT')
        if not root:
            launcher = shutil.which('flutter', path=environment.get('PATH'))
            if not launcher:
                raise RuntimeError('Flutter launcher unavailable; prepare the pinned SDK')
            root = str(Path(launcher).parent.parent)
        root = Path(root)
        dart = root/'bin/cache/dart-sdk/bin/dart.exe'
        snapshot = root/'bin/cache/flutter_tools.snapshot'
        if not dart.is_file() or not snapshot.is_file():
            raise RuntimeError('Prepared Flutter Dart executable or tools snapshot missing')
        return [str(dart), str(snapshot), 'test', *arguments]
    launcher = shutil.which('flutter', path=environment.get('PATH'))
    if not launcher:
        raise RuntimeError('Flutter launcher unavailable; prepare the pinned SDK')
    return [launcher, 'test', *arguments]


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    if not arguments: raise SystemExit('Pass Flutter test paths/options')
    try:
        invocation = command(arguments)
        with without_native_builds(Path('pubspec.yaml')):
            return subprocess.run(invocation).returncode
    except (OSError, RuntimeError) as error:
        print('Flutter checks failed: '+str(error), file=sys.stderr)
        return 1


if __name__ == '__main__': raise SystemExit(main())
