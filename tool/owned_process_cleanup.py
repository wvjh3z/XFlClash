"""Bounded cleanup of a Popen child started with start_new_session=True.

Only signal the child's private group. A Darwin EPERM can describe an exited,
unreaped group; it is not success until wait and a fresh group inventory agree.
No command lines, paths, PIDs or exception messages enter diagnostics.
"""
from __future__ import annotations

import errno
import os
import re
import signal
import subprocess
import time


class CleanupError(RuntimeError):
    def __init__(self, diagnostic):
        super().__init__('owned_process_cleanup_failed')
        self.diagnostic = diagnostic


def safe_cleanup(value):
    """Validate even injected diagnostics before copying them to a public report."""
    if not isinstance(value, dict):
        return {}
    result = {}
    for key, allowed in (
        ('outcome', {'complete', 'failed'}),
        ('phase', {'guard', 'term', 'kill', 'wait', 'verify', 'complete', 'job'}),
        ('group_state', {'gone', 'zombies_only', 'live', 'unknown'}),
    ):
        if value.get(key) in allowed:
            result[key] = value[key]
    for key in ('reaped', 'permission_race_recovered'):
        if type(value.get(key)) is bool:
            result[key] = value[key]
    errors = []
    supplied = value.get('errors', [])
    for error in (supplied[:8] if isinstance(supplied, list) else []):
        if not isinstance(error, dict):
            continue
        if error.get('phase') not in {'term', 'kill', 'wait', 'verify', 'guard', 'job'}:
            continue
        if error.get('kind') not in {'permission', 'missing', 'timeout', 'os_error', 'invalid', 'other'}:
            continue
        row = {'phase': error['phase'], 'kind': error['kind']}
        number = error.get('errno')
        if type(number) is int and 0 <= number <= 65535:
            row['errno'] = number
        errors.append(row)
    result['errors'] = errors
    return result


def error_row(phase, error):
    kind = ('permission' if isinstance(error, PermissionError) else
            'missing' if isinstance(error, ProcessLookupError) else
            'timeout' if isinstance(error, subprocess.TimeoutExpired) else
            'os_error' if isinstance(error, OSError) else
            'invalid' if isinstance(error, ValueError) else 'other')
    return {'phase': phase, 'kind': kind, 'errno': getattr(error, 'errno', None)}


def group_state(pgid, timeout):
    # Separate -o fields work with both BSD/macOS and GNU ps. No argv is queried.
    result = subprocess.run(['/bin/ps', '-A', '-o', 'pgid=', '-o', 'stat='],
                            capture_output=True, text=True, encoding="utf-8", timeout=timeout, check=True,
                            env={**os.environ, 'LC_ALL': 'C'})
    if len(result.stdout) > 4 * 1024 * 1024 or not result.stdout.strip():
        raise ValueError('invalid_process_inventory')
    members = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2 or not fields[0].isdigit() or not re.fullmatch(r'[A-Za-z+<>=?-]+', fields[1]):
            raise ValueError('invalid_process_inventory')
        if int(fields[0]) == pgid:
            members.append(fields[1])
    if not members:
        return 'gone'
    return 'zombies_only' if all(state.startswith('Z') for state in members) else 'live'


def cleanup_owned_group(process, *, timeout=3.0, grace=.1):
    state = {'outcome': 'failed', 'phase': 'guard', 'group_state': 'unknown',
             'reaped': False, 'permission_race_recovered': False, 'errors': []}
    # Never accept caller's group, group zero, or a non-PID. Callers create the
    # session at launch; keeping pgid=child.pid also covers an already exited leader.
    if os.name != 'posix' or type(process.pid) is not int or process.pid <= 1 or process.pid == os.getpgrp():
        raise CleanupError(safe_cleanup(state))
    deadline = time.monotonic() + timeout
    hard_error = False
    permission = False
    for sig, phase in ((signal.SIGTERM, 'term'), (signal.SIGKILL, 'kill')):
        state['phase'] = phase
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        except OSError as error:
            state['errors'].append(error_row(phase, error))
            if error.errno == errno.EPERM:
                permission = True
            else:
                hard_error = True
        # Always reap, including after signal errors. KILL still targets the
        # group after leader exit to stop descendants inheriting pipes/cache work.
        state['phase'] = 'wait'
        try:
            remaining = max(.001, deadline - time.monotonic())
            process.wait(timeout=min(grace if phase == 'term' else .5, remaining))
        except subprocess.TimeoutExpired as error:
            if phase == 'kill':
                state['errors'].append(error_row('wait', error))
        except (OSError, subprocess.SubprocessError) as error:
            state['errors'].append(error_row('wait', error))
            hard_error = True
    state['reaped'] = process.returncode is not None
    state['phase'] = 'verify'
    while time.monotonic() < deadline:
        try:
            state['group_state'] = group_state(process.pid, min(.5, max(.001, deadline - time.monotonic())))
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            state['errors'].append(error_row('verify', error))
            hard_error = True
            break
        # Reap a leader whose SIGKILL completed between wait and this inventory.
        if not state['reaped']:
            try:
                process.wait(timeout=min(.05, max(.001, deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                pass
            except (OSError, subprocess.SubprocessError) as error:
                state['errors'].append(error_row('wait', error))
                hard_error = True
            state['reaped'] = process.returncode is not None
        if state['group_state'] in {'gone', 'zombies_only'} and state['reaped']:
            if not hard_error:
                state.update(outcome='complete', phase='complete', permission_race_recovered=permission)
                return safe_cleanup(state)
            break
        time.sleep(min(.02, max(0, deadline - time.monotonic())))
    raise CleanupError(safe_cleanup(state))
