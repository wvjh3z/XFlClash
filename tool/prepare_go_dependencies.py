#!/usr/bin/env python3
"""Download the pinned Go module graph before native hooks; never compile."""
import hashlib
import os
from pathlib import Path
import shutil
import signal
import sys
import json
import subprocess
import tempfile

from pub_get_retry import execute, write_report


def snapshot(core):
    if core.is_symlink() or (core / 'Clash.Meta').is_symlink():
        raise RuntimeError('Go module directory symlink rejected')
    result = {}
    for relative in ('go.mod', 'go.sum', 'Clash.Meta/go.mod', 'Clash.Meta/go.sum'):
        path = core / relative
        if path.is_symlink():
            raise RuntimeError('Go module input symlink rejected: ' + relative)
        result[relative] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    if result['go.mod'] is None or result['Clash.Meta/go.mod'] is None:
        raise RuntimeError('Initialize pinned Go modules before dependency preparation')
    return result


def validate_replacements(folder, go, env):
    # `edit -json` only parses the isolated manifest; it does not fetch modules.
    for relative, allowed in (('.', {'./Clash.Meta'}), ('Clash.Meta', set())):
        result = subprocess.run(
            [go, 'mod', 'edit', '-json'], cwd=folder / relative, env=env,
            capture_output=True, encoding='utf-8', errors='replace', timeout=20,
        )
        if result.returncode:
            raise RuntimeError('Cannot inspect isolated Go module manifest')
        for item in json.loads(result.stdout).get('Replace') or []:
            target = item['New']
            if not target.get('Version') and target.get('Path') not in allowed:
                raise RuntimeError('Unregistered local Go replacement rejected')


def prepare(root, *, runner=execute, environment=None):
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(errors='backslashreplace')
    root = Path(root)
    report_environment = os.environ if environment is None else environment
    destination = report_environment.get('XFLCLASH_DIAGNOSTICS_DIR')
    report = (Path(destination) if destination else root / 'build') / 'dependency-retries/go.json'
    # Overwrite an earlier success even if validation or process startup fails.
    write_report(report, {'passed': False, 'stage': 'inputs'})
    core = root / 'core'
    before = snapshot(core)
    env = dict(os.environ if environment is None else environment)
    go = shutil.which('go', path=env.get('PATH', ''))
    if not go:
        raise RuntimeError('Go unavailable on native preparation PATH')
    # Persisted GOENV/GOFLAGS could redirect -modfile outside the sandbox.
    env.update(GOWORK='off', GOTOOLCHAIN='local', GOENV='off', GOFLAGS='')
    for key in ('GOMODCACHE', 'GOCACHE', 'GOPATH'):
        for value in env.get(key, '').split(os.pathsep):
            if value and Path(value).resolve().is_relative_to(root.resolve()):
                raise RuntimeError('Go cache must be outside the source checkout: ' + key)
    evidence = {'passed': False, 'stage': 'download', 'inputs_before': before}
    write_report(report, evidence)
    cancelled = [0]
    previous = {}
    def cancel(signum, frame):
        cancelled[0] = signum
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.signal(sig, cancel)
    try:
        with tempfile.TemporaryDirectory(prefix='xb-go-modules-') as temporary:
            isolated = Path(temporary)
            if isolated.resolve().is_relative_to(root.resolve()):
                raise RuntimeError('Go isolated manifests must be outside the checkout')
            for relative, digest in before.items():
                if digest is None:
                    continue
                destination = isolated / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((core / relative).read_bytes())
            validate_replacements(isolated, go, env)
            code, retry = runner(
                [go, 'mod', 'download'], isolated, env,
                attempts=3, attempt_timeout=300, total_timeout=720,
                cancelled=lambda: cancelled[0],
                emit=lambda line: print(line.replace('[pub-get', '[go-deps')),
            )
            evidence['isolated_changed_inputs'] = [
                name for name, digest in snapshot(isolated).items()
                if digest != before[name]
            ]
        if cancelled[0]:
            raise SystemExit(128 + cancelled[0])
        after = snapshot(core)
        changed = [name for name in before if before[name] != after[name]]
        evidence.update(retry=retry, inputs_after=after, changed_inputs=changed)
        manifest_changed = any(name.endswith('go.mod') for name in evidence['isolated_changed_inputs'])
        evidence['passed'] = code == 0 and not changed and not manifest_changed
        evidence['stage'] = ('complete' if evidence['passed'] else
                             'inputs_changed' if changed else
                             'isolated_manifest_changed' if manifest_changed else 'download_failed')
        if cancelled[0]:
            raise SystemExit(128 + cancelled[0])
        if not evidence['passed']:
            raise RuntimeError('Go dependency preparation failed: ' + evidence['stage'])
    except BaseException as error:
        evidence['failure_type'] = type(error).__name__
        raise
    finally:
        pending_error = sys.exc_info()[0] is not None
        try:
            if cancelled[0]:
                evidence.update(passed=False, stage='cancelled', exit_code=128 + cancelled[0])
            write_report(report, evidence)
            # A cancellation can arrive during atomic report publication too.
            if cancelled[0] and evidence['stage'] != 'cancelled':
                evidence.update(passed=False, stage='cancelled', exit_code=128 + cancelled[0])
                write_report(report, evidence)
        except Exception:
            if not pending_error and not cancelled[0]:
                raise
            print('Go report write failed; original failure/cancellation retained', file=sys.stderr)
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        if cancelled[0] and not pending_error:
            raise SystemExit(128 + cancelled[0])
    print('Pinned Go dependencies ready; module files unchanged')


if __name__ == '__main__':
    try:
        prepare(Path(__file__).resolve().parents[1])
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
