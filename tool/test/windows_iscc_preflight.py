"""Compile both real maker-rendered installer scripts with ISCC /O-.

No client build, installed program, VC installation or download. Only a temporary
copy's ISPP Exec boundary is replaced by an argument-checking macro. The complete
production Pascal code and file/language directives still go through real ISCC.
No bypass switch is added to the production installer.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXED_ROOT = 'AddBackslash(ExtractFileDir(RemoveBackslashUnlessRoot(SourcePath)))'
FIXED_BUNDLE = '(AddBackslash(SourcePath) + XbBundle)'


def find_packages(root=ROOT):
    caches = [os.environ.get('PUB_CACHE')]
    if os.name == 'nt':
        caches.append(str(Path(os.environ.get('LOCALAPPDATA', '')) / 'Pub/Cache'))
    else:
        caches.append(str(Path.home() / '.pub-cache'))
    # Prefer the activated graph used by formal dart pub global run packaging.
    candidates = [Path(cache) / 'global_packages/flutter_distributor/.dart_tool/package_config.json'
                  for cache in caches if cache]
    candidates.append(root / 'plugins/flutter_distributor/packages/flutter_distributor/.dart_tool/package_config.json')
    for path in candidates:
        if path.is_file():
            names = {p['name'] for p in json.loads(path.read_text(encoding='utf-8'))['packages']}
            if {'flutter_app_packager', 'liquid_engine', 'yaml', 'args'} <= names:
                return path
    raise RuntimeError('Activate the existing flutter_distributor before ISCC preflight; package config missing')


def windows_path(path, wine):
    path = Path(path).resolve()
    return 'Z:' + str(path).replace('/', '\\') if wine else str(path)


def ispp_string(value):
    return '"' + value.replace('"', '""') + '"'


def fixture_header(row, wine, exit_code):
    root = windows_path(row['root'], wine).rstrip('\\') + '\\'
    bundle = windows_path(row['bundle'], wine)
    args = ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + root +
            'tool\\windows\\prepare_vc_runtime.ps1" -Root "' + root + '." -Bundle "' + bundle + '"')
    # Compare the REAL production expression's evaluated arguments against paths
    # supplied by the maker fixture manifest, not a second copy of the path logic.
    return '\n'.join([
        '#define XbExpectedRoot ' + ispp_string(root),
        '#define XbExpectedArgs ' + ispp_string(args),
        '#define XbPreflightExec(str File, str Args, str Dir, int Wait, int Show) \\',
        '  (File == GetEnv("SystemRoot") + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" && \\',
        '   Args == XbExpectedArgs && Dir == XbExpectedRoot && Wait == 1 && Show == 0) ? ' + str(exit_code) + ' : 99',
        '',
    ])


def variant(source, name):
    if source.count('#if Exec(') != 1 or source.count(FIXED_ROOT) != 1 or source.count(FIXED_BUNDLE) != 1:
        raise RuntimeError('Production ISPP boundary changed; review the preflight fixture')
    value = source.replace('#if Exec(', '#if XbPreflightExec(', 1)
    if name == 'old_root':
        value = value.replace(FIXED_ROOT, 'AddBackslash(ExpandFileName(AddBackslash(SourcePath) + ".."))', 1)
    elif name == 'old_bundle':
        value = value.replace(FIXED_BUNDLE, 'ExpandFileName(AddBackslash(SourcePath) + XbBundle)', 1)
    elif name == 'bad_pascal':
        if value.count("  Result := '';") != 1:
            raise RuntimeError('PrepareToInstall boundary changed')
        value = value.replace("  Result := '';", "  XbMissingPascalFunction;\n  Result := '';", 1)
    return value


def compile_case(command, script, wine):
    result = subprocess.run([*command, '/O-', windows_path(script, wine)],
                            capture_output=True, encoding='utf-8', errors='replace', timeout=60)
    return result.returncode, result.stdout + result.stderr


def run(args):
    packages = args.packages or find_packages()
    compiler = args.iscc
    if not compiler and os.name == 'nt':
        # Match the vendored maker's compiler, even if PATH contains another Inno.
        compiler = r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
    elif not compiler:
        compiler = shutil.which('ISCC.exe')
    if not compiler or not Path(compiler).is_file():
        raise RuntimeError('Real ISCC is required; this preflight must not silently skip')
    native_dart = Path(os.environ.get('FLUTTER_ROOT', '')) / 'bin/cache/dart-sdk/bin/dart.exe'
    dart = args.dart or (native_dart if os.name == 'nt' and native_dart.is_file() else shutil.which('dart'))
    if not dart:
        raise RuntimeError('Dart is required for the real installer maker')
    command = ([str(args.wine), windows_path(compiler, True)] if args.wine else [str(compiler)])
    report = {'schema_version': 1, 'passed': False, 'client_build': False, 'installer_execution': False,
              'prepare_process_boundary': 'argument_checked_fixture', 'cases': []}
    try:
        with tempfile.TemporaryDirectory(prefix='xflclash iscc preflight ') as temporary:
            base = Path(temporary)
            manifest = base / 'fixtures.json'
            rendered = subprocess.run([str(dart), '--packages=' + str(Path(packages).resolve()),
                str(ROOT / 'tool/test/render_windows_iscc_fixture.dart'), str(ROOT), str(base), str(manifest)],
                cwd=ROOT, capture_output=True, encoding='utf-8', errors='replace', timeout=90)
            if rendered.returncode:
                raise RuntimeError('Installer fixture rendering failed:\n' + (rendered.stdout + rendered.stderr)[-6000:])
            rows = json.loads(manifest.read_text(encoding='utf-8'))
            if [r['brand'] for r in rows] != ['brand_a', 'brand_b']:
                raise RuntimeError('Both brands must be rendered')
            for row in rows:
                script = Path(row['script'])
                root = Path(row['root']).resolve()
                if not root.is_relative_to(base.resolve()) or script.resolve().parent.parent != root:
                    raise RuntimeError('Maker fixture paths escaped the isolated root')
                original_script = script.read_text(encoding='utf-8-sig')
                if ('{{' in original_script or '{%' in original_script or
                    'AppPublisher=' + row['publisher'] not in original_script or
                    'AppName=' + row['display_name'] not in original_script):
                    raise RuntimeError('Incomplete or wrong-brand maker rendering')
                include = Path(row['root']) / 'windows/packaging/exe/vc_runtime.iss'
                original_include = include.read_text(encoding='utf-8-sig')
                for name in ('positive', 'old_root', 'old_bundle', 'prepare_rejected', 'bad_pascal'):
                    script.write_text(fixture_header(row, bool(args.wine), 73 if name == 'prepare_rejected' else 0)
                                      + original_script, encoding='utf-8-sig')
                    include.write_text(variant(original_include, name), encoding='utf-8-sig')
                    code, output = compile_case(command, script, bool(args.wine))
                    expected = {'old_root': 'Undeclared identifier: ExpandFileName',
                                'old_bundle': 'Undeclared identifier: ExpandFileName',
                                'prepare_rejected': 'VC runtime preparation failed',
                                'bad_pascal': 'XbMissingPascalFunction'}.get(name)
                    passed = code == 0 if expected is None else code != 0 and expected.lower() in output.lower()
                    version = re.search(r'Compiler engine version:\s+(?:Inno Setup\s+)?([0-9.]+)', output)
                    if version:
                        report['compiler_version'] = version.group(1)
                    report['cases'].append({'brand': row['brand'], 'case': name, 'passed': passed, 'exit_code': code})
                    print(('PASS' if passed else 'FAIL') + ' ISCC ' + row['brand'] + ' ' + name, flush=True)
                    if not passed:
                        print(output[-8000:], flush=True)  # Only public fixture data, no real flavor input.
                if any(script.parent.glob('*setup.exe')):
                    raise RuntimeError('Preflight unexpectedly created an installer; /O- must be honored')
        report['passed'] = len(report['cases']) == 10 and all(row['passed'] for row in report['cases'])
        return 0 if report['passed'] else 1
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iscc', type=Path)
    parser.add_argument('--wine', type=Path, help='Optional isolated Linux compatibility runner; Z: must map to /')
    parser.add_argument('--dart', type=Path)
    parser.add_argument('--packages', type=Path)
    parser.add_argument('--report', type=Path, default=ROOT / 'build/windows-iscc-preflight.json')
    args = parser.parse_args()
    if args.report.is_symlink():
        raise RuntimeError('Preflight report must not be a symlink')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    # Missing tools/rendering failures must not leave a stale successful report.
    args.report.write_text(json.dumps({'schema_version': 1, 'passed': False, 'phase': 'initialization'}) + '\n', encoding='utf-8')
    return run(args)


if __name__ == '__main__':
    raise SystemExit(main())
