#!/usr/bin/env python3
"""Verify Windows target identity without executing any packaged binary."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
from sentry_elf import inspect_elf


def pe_machine(path):
    with Path(path).open('rb') as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b'MZ':
            raise ValueError('Invalid DOS header: ' + str(path))
        offset = struct.unpack_from('<I', header, 60)[0]
        if offset < 64:
            raise ValueError('Invalid PE offset: ' + str(path))
        stream.seek(offset)
        header = stream.read(6)
        if len(header) != 6 or header[:4] != b'PE\0\0':
            raise ValueError('Invalid PE header: ' + str(path))
        return struct.unpack_from('<H', header, 4)[0]


def dart_target(version):
    matches = re.findall(r'\bon "windows_(x64|arm64)"', version)
    if len(matches) != 1:
        raise ValueError('Expected one Windows Dart ABI')
    return {'x64': 'amd64', 'arm64': 'arm64'}[matches[0]]


def verify_dart(architecture, version):
    target = 'amd64' if architecture == 'x64' else architecture
    if target != dart_target(version):
        raise ValueError('Flutter Windows requires a native Dart host matching the release target')


def verify_bundle(bundle, architecture):
    target = 'x64' if architecture == 'amd64' else architecture
    machines = {'x64': {0x8664}, 'arm64': {0xaa64, 0xa64e}}.get(target)
    if machines is None:
        raise ValueError('Unsupported Windows target')
    bundle = Path(bundle)
    runners = [bundle / name for name in ('OmoFly.exe', 'Daishu.exe', 'FlClash.exe') if (bundle / name).is_file()]
    if len(runners) != 1 or not (bundle / 'flutter_windows.dll').is_file() or not (bundle / 'data/app.so').is_file():
        raise ValueError('Incomplete Windows release bundle')
    # Flutter's WindowsAotBundle also uses AotElfRelease, not a PE DLL.
    aot = inspect_elf(bundle / 'data/app.so')
    if aot['architecture'] != {'x64': 'x86_64', 'arm64': 'aarch64'}[target] or not aot['has_executable_text']:
        raise ValueError('Wrong Windows AOT architecture or missing executable text')
    facts = [{'file': 'data/app.so', 'format': 'elf', 'architecture': aot['architecture']}]
    for path in sorted(bundle.rglob('*')):
        if not path.is_file() or path.suffix.lower() not in ('.exe', '.dll'):
            continue
        relative = path.relative_to(bundle).as_posix()
        machine = pe_machine(path)
        # Existing standalone upstream utility, not a module loaded by the app.
        allowed = {0x14c} if relative == 'EnableLoopback.exe' else machines
        if machine not in allowed:
            raise ValueError('Wrong PE architecture: ' + relative + ' machine=' + hex(machine))
        facts.append({'file': relative, 'machine': hex(machine)})
    return {'architecture': target, 'files': facts, 'passed': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--architecture', choices=('amd64', 'x64', 'arm64'))
    mode.add_argument('--print-target', action='store_true', help='Print the prepared Dart SDK target for local auto selection')
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--report', type=Path, default=Path('build/windows-architecture.json'))
    args = parser.parse_args()
    if args.print_target and args.bundle:
        parser.error('--print-target only inspects the prepared SDK')
    if args.bundle:
        # Invalidate previous success even when this candidate fails validation.
        args.report.unlink(missing_ok=True)
        report = verify_bundle(args.bundle, args.architecture)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    else:
        dart = Path(os.environ['FLUTTER_ROOT']) / 'bin/cache/dart-sdk/bin/dart.exe'
        result = subprocess.run([str(dart), '--version'], capture_output=True, text=True, timeout=30, check=True)
        if args.print_target:
            print(dart_target(result.stdout + result.stderr))
            return
        verify_dart(args.architecture, result.stdout + result.stderr)
    print('Windows target identity verified: ' + args.architecture)


if __name__ == '__main__':
    main()
