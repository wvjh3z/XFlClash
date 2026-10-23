#!/usr/bin/env python3
"""Shared release-tool activation and isolated cold-start checks; never build clients."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import tempfile

from pub_get_retry import execute, clean_environment
from distributor_graph import resolved_packages

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path('build/packaging-tools/flutter_distributor/packages/flutter_distributor')
PLATFORMS = ('android', 'windows', 'linux', 'macos')


class PreflightError(RuntimeError):
    pass


def native_dart(environment):
    suffix = 'dart.exe' if os.name == 'nt' else 'dart'
    root = Path(environment.get('FLUTTER_ROOT', ''))
    native = root / 'bin/cache/dart-sdk/bin' / suffix
    if native.is_file():
        return str(native.resolve())
    executable = shutil.which('dart', path=environment.get('PATH'))
    if executable:
        bundled = Path(executable).resolve().parent / 'cache/dart-sdk/bin' / suffix
        if bundled.is_file():
            return str(bundled)
        if Path(executable).suffix.lower() not in ('.bat', '.cmd'):
            return executable
    raise PreflightError('native_dart_missing')


def validate_host(target, wine=None):
    expected = {'windows': 'win32', 'macos': 'darwin', 'linux': 'linux', 'android': 'linux'}[target]
    if sys.platform != expected and not (target == 'windows' and wine and sys.platform == 'linux'):
        raise PreflightError('platform_requires_native_host')


def isolated_environment(base, environment):
    env = clean_environment(environment)
    for name in list(env):
        if (name.startswith('GIT_') or name in ('PYTHONPATH', 'PYTHONHOME', 'DART_VM_OPTIONS',
                'PUB_CACHE', 'PUB_HOSTED_URL', 'SSH_AUTH_SOCK', 'GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_OUTPUT')):
            env.pop(name)
    home = base / 'home'; cache = base / 'pub-cache'
    home.mkdir(); cache.mkdir()
    env.update(HOME=str(home), USERPROFILE=str(home), PUB_CACHE=str(cache),
               XDG_CONFIG_HOME=str(home/'config'), APPDATA=str(home/'AppData/Roaming'),
               LOCALAPPDATA=str(home/'AppData/Local'), GIT_TERMINAL_PROMPT='0',
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    return env


class Runner:
    def __init__(self, report, cancelled=lambda: 0):
        self.path = Path(report).resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.cancelled = cancelled
        self.data = {'schema_version': 1, 'passed': False, 'client_build': False, 'steps': []}
        self.save()

    def save(self):
        self.path.write_text(json.dumps(self.data, indent=2)+'\n', encoding='utf-8')

    def run(self, label, command, root, environment, timeout=120):
        lines = []
        # Shared owned-process runner bounds output and kills descendants on all
        # supported hosts. One attempt: no automatic build/test retries.
        code, evidence = execute([str(x) for x in command], root, environment,
                                 attempts=1, attempt_timeout=timeout, total_timeout=timeout,
                                 cancelled=self.cancelled, emit=lines.append)
        self.data['steps'].append({'name': label, 'exit_code': code, **evidence})
        self.save()
        (self.path.parent / (self.path.stem+'-'+label+'.log')).write_text('\n'.join(lines)+'\n', encoding='utf-8')
        print(f'[distributor-preflight] {label}: {"passed" if code == 0 else "failed"}', flush=True)
        if code:
            raise PreflightError('stage_failed:'+label)
        prefix = '[pub-get output] '
        return '\n'.join(line[len(prefix):] for line in lines if line.startswith(prefix))


def activate(root, environment, runner):
    dart = native_dart(environment)
    runner.run('prepare', [sys.executable, 'tool/prepare_linux_packager.py'], root, environment)
    runner.run('activate', [dart, 'pub', 'global', 'activate', '-s', 'path', TOOL.as_posix()],
               root, environment, 480)
    prepared = root / TOOL.parent
    try:
        resolved_packages(root/TOOL/'.dart_tool/package_config.json', prepared=prepared)
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        raise PreflightError('prepared_graph_invalid') from error
    listing = runner.run('global-list', [dart, 'pub', 'global', 'list'], root, environment)
    matches = re.findall(r'^flutter_distributor\s+\S+\s+at path "([^"\n]+)"\s*$', listing, re.M)
    if len(matches) != 1 or Path(matches[0]).resolve() != (root/TOOL).resolve():
        raise PreflightError('global_activation_points_elsewhere')
    output = runner.run('global-cli', [dart, 'pub', 'global', 'run', 'flutter_distributor:main', '--help'],
                        root, environment)
    if 'Usage: flutter_distributor' not in output or not re.search(r'^\s+package\s+', output, re.M):
        raise PreflightError('unexpected_global_cli')


def platform_commands(target, *, dart, wine=None, iscc=None):
    commands = [('brand-identity', [sys.executable, 'tool/test/brand_identity_cli_test.py'], 180),
                ('context', [sys.executable, 'tool/test/packager_context_test.py'], 180),
                ('flutter-defines', [sys.executable, 'tool/test/flutter_reserved_defines_test.py'], 480)]
    if target == 'android':
        commands += [('android-arguments', [sys.executable, 'tool/test/android_package_arguments_test.py'], 180),
                     ('android-artifacts', [sys.executable, 'tool/test/android_artifact_pipeline_test.py'], 180)]
    elif target == 'linux':
        commands += [('appimage-contract', [sys.executable, '-m', 'unittest', 'tool.test.appimagetool_contract_test'], 180),
                     ('linux-maker', [sys.executable, '-m', 'unittest', 'tool.test.linux_appimage_packaging_test', 'tool.test.linux_package_permissions_test', 'tool.test.linux_release_packages_test', 'tool.test.linux_appimage_readback_test', 'tool.test.linux_webview_identity_test'], 480)]
    elif target == 'windows':
        args = [sys.executable, 'tool/test/windows_iscc_preflight.py', '--dart', dart]
        if wine: args += ['--wine', str(wine)]
        if iscc: args += ['--iscc', str(iscc)]
        commands += [('windows-branded-cmake', [sys.executable, 'tool/test/windows_loader_install_test.py', '--brand-only'], 300),
                     ('windows-iscc', args, 300)]
    # macOS checks the real CLI, graph and Git context. DMG/Xcode builds remain
    # the separate production Package step, not a pretend Linux substitute.
    return commands


def cold_start(root, environment, runner, target, *, revision='HEAD', wine=None, iscc=None):
    validate_host(target, wine)
    native_dart(environment)  # Fail before cloning/downloading if unavailable.
    source = runner.run('source-revision', ['git', 'rev-parse', '--verify', revision+'^{commit}'], root, environment).strip()
    if not re.fullmatch('[0-9a-f]{40}', source):
        raise PreflightError('invalid_source_revision')
    runner.data.update(source_revision=source, platform=target, cold_cache=True, windows_compatibility_runner=bool(wine))
    with tempfile.TemporaryDirectory(prefix='distributor-cold-') as temporary:
        base = Path(temporary).resolve()
        env = isolated_environment(base, environment)
        checkout = base / 'checkout'
        runner.run('clone', ['git', 'clone', '--quiet', '--shared', '--no-checkout', '--template=', '--config', 'core.longpaths=true', str(root), str(checkout)], base, env)
        runner.run('checkout', ['git', 'checkout', '--quiet', '--detach', source], checkout, env)
        if (checkout/'tool/distributor_preflight.py').read_text(encoding='utf-8') != Path(__file__).read_text(encoding='utf-8'):
            raise PreflightError('revision_does_not_match_entrypoint')
        # The source is fetched by the same immutable-pin entry as activation;
        # do not clone a warmed submodule from the developer's checkout.
        for relative in ('.dart_tool', 'build', '.local-build'):
            if (checkout/relative).exists(): raise PreflightError('cold_workspace_contains_cache')
        if any(Path(env['PUB_CACHE']).iterdir()): raise PreflightError('cold_pub_cache_not_empty')
        runner.data['initial_cache_empty'] = True
        runner.save()
        activate(checkout, env, runner)
        env.update(LINUX_PACKAGER_REQUIRE_DART='1', APPIMAGETOOL_REQUIRE_REAL='1')
        env['APPIMAGETOOL_DIRECTORY'] = str(Path(environment.get('APPIMAGETOOL_DIRECTORY',
            str(root/'.local-build/packaging-tools/appimagetool'))).resolve())
        for label, command, timeout in platform_commands(target, dart=native_dart(env), wine=wine, iscc=iscc):
            runner.run(label, command, checkout, env, timeout)
        if target == 'windows':
            shutil.copyfile(checkout/'build/windows-iscc-preflight.json', runner.path.parent/'windows-iscc-preflight.json')
    runner.data['temporary_workspace_removed'] = True


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('activate', 'cold'))
    p.add_argument('--platform', choices=PLATFORMS)
    p.add_argument('--revision', default='HEAD', help='Cold check source commit; defaults to the CI checkout HEAD')
    p.add_argument('--report', type=Path)
    p.add_argument('--wine', type=Path, help='Local Windows fixture only; reports compatibility runner instead of native Windows')
    p.add_argument('--iscc', type=Path)
    args = p.parse_args(argv)
    if args.action == 'cold' and not args.platform: p.error('cold requires --platform')
    cancelled = [0]
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    for sig in handlers: signal.signal(sig, lambda value, frame: cancelled.__setitem__(0, value))
    runner = Runner(args.report or ROOT/f'build/distributor-preflight/{args.action}.json', lambda: cancelled[0])
    try:
        if args.action == 'activate': activate(ROOT, os.environ, runner)
        else: cold_start(ROOT, os.environ, runner, args.platform, revision=args.revision, wine=args.wine, iscc=args.iscc)
        runner.data['passed'] = True
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        # Only fixed failure categories are emitted. Detailed child output has
        # already passed the owned runner's credential/query/workflow sanitizer.
        runner.data['error'] = str(error) if isinstance(error, PreflightError) else type(error).__name__
        print('[distributor-preflight] failed: '+runner.data['error'], file=sys.stderr)
        return 1
    finally:
        runner.save()
        for sig, handler in handlers.items(): signal.signal(sig, handler)


if __name__ == '__main__':
    raise SystemExit(main())
