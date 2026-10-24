"""Bounded Linux-only native test supervision; no application runtime changes."""
import contextlib
import json
import subprocess
import time
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pub_get_retry import stop_tree


class ProbeFailure(RuntimeError):
    pass


def wait_ready(process, ready, *, phase, timeout, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    while True:
        if process.poll() is not None:
            raise ProbeFailure(f'{phase}: exited before readiness (exit={process.returncode})')
        value = ready()
        if value:
            return value
        if clock() >= deadline:
            raise ProbeFailure(f'{phase}: readiness timeout ({timeout}s)')
        sleep(.02)


def wait_complete(process, stdout, *, timeout=60):
    try:
        code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        phases = [line for line in stdout.read_text(errors='replace').splitlines()
                  if line.startswith('PHASE=')]
        raise ProbeFailure('probe timeout; last_phase=' +
                           (phases[-1] if phases else 'before_main')) from error
    if code != 0:
        raise ProbeFailure(f'probe exit={code}')
    text = stdout.read_text(errors='replace')
    if 'PHASE=complete' not in text.splitlines():
        raise ProbeFailure('probe exited without completion marker')
    return text


@contextlib.contextmanager
def owned(command, directory, name, *, env=None, pass_fds=()):
    stdout = directory/(name+'.stdout')
    stderr = directory/(name+'.stderr')
    with stdout.open('wb') as out, stderr.open('wb') as err:
        process = subprocess.Popen(command, env=env, stdout=out, stderr=err,
                                   start_new_session=True, pass_fds=pass_fds,
                                   stdin=subprocess.DEVNULL)
        try:
            yield process, stdout, stderr
        except Exception as error:
            # These files contain only isolated fixture output, not app traffic.
            raise ProbeFailure(f'{name}: {error}; stdout={stdout.read_text(errors="replace")[-4096:]!r}; '
                               f'stderr={stderr.read_text(errors="replace")[-4096:]!r}') from error
        finally:
            diagnostic = {}
            if not stop_tree(process, diagnostic=diagnostic):
                raise ProbeFailure(f'{name}: cleanup failed: {json.dumps(diagnostic)}')
