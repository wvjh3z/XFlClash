#!/usr/bin/env python3
"""Bounded pub-get retries. No dependency upgrades, cache repair or build retries.

Only a reviewed network diagnostic (or this dependency-only command timing out)
allows retry. Deterministic failures take precedence. Child output is streamed
with credential/URL-query masking; reports contain fixed categories only.
"""
from __future__ import annotations

import argparse
import codecs
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PERMANENT = {
    'dependency_resolution': r'version solving failed|version solver failed|could not resolve packages|requires (?:the )?(?:dart |flutter )?sdk version|sdk version constraint|doesn.t support null safety',
    'authentication': r'authentication failed|permission denied|terminal prompts disabled|could not read username|repository not found|\b401\b.*unauthorized|\b403\b.*forbidden|http basic: access denied|requested url returned error: (?:401|403)|http code 407',
    'certificate': r'certificate verify failed|certificate verification failed|certificate_verify_failed|ssl certificate problem|unable to get local issuer certificate|self.signed certificate|certificate has expired',
    'configuration': r'could not find a file named [\x27\x22]?pubspec.yaml|error (?:on|in) line .*pubspec.yaml|couldn.t find remote ref|unknown revision|reference is not a tree|not a valid object name|could not find package .* at|path dependency .*does not exist|\b404\b.*not found|requested url returned error: 404',
    'local_storage': r'no space left on device|disk full|read.only file system|access is denied',
}
NETWORK = {
    'dns': r'could not resolve host|failed host lookup|temporary failure in name resolution|\benotfound\b|\beai_again\b',
    'connection': r'connection (?:reset|timed out|aborted|refused)|operation timed out|network is unreachable|recv failure|connection closed before full header|remote end hung up unexpectedly',
    'git_transport': r'rpc failed; curl (?:5|6|7|18|28|35|52|55|56|92)\b|unexpected disconnect while reading sideband packet',
    'http_unavailable': r'(?:http(?: error| status| status code)?[ :/=]+|status code[ :/=]+|requested url returned error: )(?:429|500|502|503|504)\b',
}
PATTERNS = {kind: {key: re.compile(pattern, re.I) for key, pattern in values.items()}
            for kind, values in [('permanent', PERMANENT), ('network', NETWORK)]}
IS_WINDOWS = os.name == 'nt'
MAX_OUTPUT = 4 * 1024 * 1024
MAX_LINE = 32 * 1024


def clean_environment(environment):
    result = {k: v for k, v in environment.items()
              if not k.upper().startswith(('SENTRY_', 'GIT_TRACE', 'GIT_CONFIG_'))
              and not any(word in k.upper() for word in ('TOKEN', 'PASSWORD', 'SECRET', 'DSN', 'AES_KEY'))}
    result.update(GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='', SSH_ASKPASS='')
    return result


class Output:
    def __init__(self, emit, environment):
        self.emit = emit
        self.hidden = [v for k, v in environment.items() if len(v) >= 4 and
                       any(w in k.upper() for w in ('TOKEN', 'PASSWORD', 'SECRET', 'DSN', 'AES_KEY'))]
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.tail = ''
        self.pending = ''
        self.long_line = False
        self.categories = {'permanent': set(), 'network': set()}

    def line(self, line):
        for value in self.hidden:
            line = line.replace(value, '[credential]')
        line = re.sub(r'(https?://)[^\s/]+@', r'\1[credential]@', line, flags=re.I)
        line = re.sub(r'(https?://[^\s?]+)\?[^\s]+', r'\1?[query]', line, flags=re.I)
        line = re.sub(r'(?i)(authorization\s*[:=]\s*(?:bearer|basic)?\s*)[^\s,;]+', r'\1[credential]', line)
        line = re.sub(r"(?i)((?:token|password|secret|dsn)[\"']?\s*[:=]\s*[\"']?)[^\s,;}\"']+", r'\1[credential]', line)
        line = re.sub(r'\b(?:gh[pousr]_|github_pat_|sntrys_|sntryu_)[A-Za-z0-9_=-]+', '[credential]', line)
        # Child output must never become an Actions workflow command.
        self.emit('[pub-get output] ' + line.replace('::', ': :'))

    def feed(self, chunk, final=False):
        text = self.decoder.decode(chunk, final=final)
        scan = self.tail + text
        for kind, patterns in PATTERNS.items():
            self.categories[kind].update(k for k, pattern in patterns.items() if pattern.search(scan))
        self.tail = scan[-2048:]
        for part in text.splitlines(keepends=True):
            self.pending += part
            if len(self.pending.encode('utf-8')) > MAX_LINE:
                self.pending = ''
                self.long_line = True
            if part.endswith(('\n', '\r')):
                if self.long_line:
                    self.emit('[pub-get output] [oversized line omitted]')
                else:
                    self.line(self.pending.rstrip('\r\n'))
                self.pending = ''
                self.long_line = False
        if final and (self.pending or self.long_line):
            if self.long_line:
                self.emit('[pub-get output] [oversized line omitted]')
            else:
                self.line(self.pending)
            self.pending = ''


class WindowsJob:
    """Kill-on-close Job Object; worker waits for assignment before spawning pub."""
    def __init__(self):
        import ctypes as c
        from ctypes import wintypes as w
        class Basic(c.Structure):
            _fields_ = [('user', c.c_int64), ('job_user', c.c_int64), ('flags', w.DWORD),
                        ('min_ws', c.c_size_t), ('max_ws', c.c_size_t), ('active_limit', w.DWORD),
                        ('affinity', c.c_size_t), ('priority', w.DWORD), ('scheduling', w.DWORD)]
        class IO(c.Structure):
            _fields_ = [(x, c.c_uint64) for x in ('read', 'write', 'other', 'read_bytes', 'write_bytes', 'other_bytes')]
        class Extended(c.Structure):
            _fields_ = [('basic', Basic), ('io', IO), ('process_memory', c.c_size_t),
                        ('job_memory', c.c_size_t), ('peak_process', c.c_size_t), ('peak_job', c.c_size_t)]
        class Accounting(c.Structure):
            _fields_ = [(x, c.c_int64) for x in ('user', 'kernel', 'period_user', 'period_kernel')] + [
                (x, w.DWORD) for x in ('faults', 'total', 'active', 'terminated')]
        self.c, self.accounting = c, Accounting
        self.api = c.WinDLL('kernel32', use_last_error=True)
        for name, args, result in [
            ('CreateJobObjectW', [c.c_void_p, w.LPCWSTR], w.HANDLE),
            ('SetInformationJobObject', [w.HANDLE, c.c_int, c.c_void_p, w.DWORD], w.BOOL),
            ('AssignProcessToJobObject', [w.HANDLE, w.HANDLE], w.BOOL),
            ('TerminateJobObject', [w.HANDLE, w.UINT], w.BOOL),
            ('QueryInformationJobObject', [w.HANDLE, c.c_int, c.c_void_p, w.DWORD, c.c_void_p], w.BOOL),
            ('CloseHandle', [w.HANDLE], w.BOOL),
        ]:
            fn = getattr(self.api, name); fn.argtypes = args; fn.restype = result
        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise OSError('windows_job_create_failed')
        info = Extended(); info.basic.flags = 0x2000
        if not self.api.SetInformationJobObject(self.handle, 9, c.byref(info), c.sizeof(info)):
            self.close(); raise OSError('windows_job_configure_failed')

    def assign(self, process):
        if not self.api.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise OSError('windows_job_assignment_failed')

    def stop(self):
        if not self.api.TerminateJobObject(self.handle, 1):
            return False
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            info = self.accounting()
            if not self.api.QueryInformationJobObject(self.handle, 1, self.c.byref(info), self.c.sizeof(info), None):
                return False
            if info.active == 0:
                return True
            time.sleep(.02)
        return False

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle); self.handle = None


def stop_tree(process, job=None):
    if job is not None:
        ok = job.stop()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            ok = False
        return ok
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        except OSError:
            return False
        if sig == signal.SIGTERM:
            time.sleep(.1)
    try:
        process.wait(timeout=3)
        # Reaped descendants can remain zombies under a container's PID 1;
        # they cannot write/cache-lock. Never retry while any live group member remains.
        result = subprocess.run(['ps', '-eo', 'pgid=,stat='], capture_output=True,
                                text=True, timeout=2, check=True)
        return not any(len(fields := line.split()) == 2 and fields[0] == str(process.pid)
                       and not fields[1].startswith('Z') for line in result.stdout.splitlines())
    except (OSError, subprocess.SubprocessError):
        return False


def worker(command):
    # A Windows process is assigned to its Job before this gate is opened.
    if sys.stdin.buffer.readline() != b'launch\n':
        return 125
    use_shell = IS_WINDOWS and Path(command[0]).suffix.lower() in ('.bat', '.cmd')
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, shell=use_shell)
    code = child.wait()
    return code if code >= 0 else 128 - code


def attempt(command, cwd, environment, timeout, cancelled, emit, output_limit=MAX_OUTPUT):
    started = time.monotonic()
    output = Output(emit, environment)
    process = job = None
    reason = 'exit'
    code = None
    cleaned = True
    cleanup_done = False
    with tempfile.TemporaryDirectory(prefix='pub-get-') as folder:
        path = Path(folder) / 'output'
        try:
            with path.open('wb') as writer, path.open('rb') as reader:
                os.chmod(path, 0o600)
                options = {'start_new_session': True, 'stdin': subprocess.DEVNULL}
                argv = command
                if IS_WINDOWS:
                    job = WindowsJob()
                    options = {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW,
                               'stdin': subprocess.PIPE}
                    argv = [sys.executable, str(Path(__file__).resolve()), '--worker', json.dumps(command)]
                process = subprocess.Popen(argv, cwd=cwd, env=clean_environment(environment),
                                           stdout=writer, stderr=subprocess.STDOUT, **options)
                if job:
                    job.assign(process)
                    process.stdin.write(b'launch\n'); process.stdin.flush(); process.stdin.close()
                heartbeat = started + 20
                while True:
                    chunk = reader.read(65536)
                    if chunk:
                        output.feed(chunk)
                    if path.stat().st_size > output_limit:
                        reason = 'output_limit'; break
                    if cancelled():
                        reason = 'cancelled'; break
                    if time.monotonic() - started >= timeout:
                        reason = 'attempt_timeout'; break
                    code = process.poll()
                    if code is not None:
                        break
                    if time.monotonic() >= heartbeat:
                        emit('[pub-get] running; elapsed_seconds=' + str(int(time.monotonic() - started)))
                        heartbeat = time.monotonic() + 20
                    time.sleep(.02)
                cleaned = stop_tree(process, job)
                cleanup_done = True
                # Retain the command's original exit code, not the cleanup signal.
                if code is None:
                    code = process.returncode
                remaining = output_limit - reader.tell()
                while remaining > 0:
                    chunk = reader.read(min(65536, remaining))
                    if not chunk:
                        break
                    output.feed(chunk); remaining -= len(chunk)
                output.feed(b'', final=True)
        except (OSError, subprocess.SubprocessError):
            reason = 'launch_or_io_error'
            if process:
                if job:
                    # If assignment failed, worker has not passed its stdin gate.
                    process.kill()
                cleaned = stop_tree(process, job)
                cleanup_done = True
        finally:
            if process and not cleanup_done:
                stop_tree(process, job)
            if job:
                job.close()
    return {'reason': reason, 'exit_code': code, 'cleanup_succeeded': cleaned,
            'elapsed_seconds': round(time.monotonic() - started, 3),
            'network': sorted(output.categories['network']),
            'permanent': sorted(output.categories['permanent'])}


def execute(command, cwd, environment, *, attempts=3, attempt_timeout=300,
            total_timeout=720, delays=(10, 30), emit=print, cancelled=lambda: 0,
            output_limit=MAX_OUTPUT):
    start = time.monotonic()
    records = []
    outcome = 'failed'
    exit_code = 1
    for index in range(attempts):
        if cancelled():
            outcome, exit_code = 'cancelled', 128 + cancelled(); break
        budget = total_timeout - (time.monotonic() - start)
        if budget <= 0:
            outcome, exit_code = 'budget_exhausted', 124; break
        emit(f'[pub-get] attempt {index + 1}/{attempts}')
        item = attempt(command, cwd, environment, min(attempt_timeout, budget), cancelled, emit, output_limit)
        records.append(item)
        if not item['cleanup_succeeded']:
            outcome, exit_code = 'cleanup_failed', 125; break
        if cancelled() or item['reason'] == 'cancelled':
            outcome, exit_code = 'cancelled', 128 + (cancelled() or signal.SIGINT)
            break
        if item['reason'] == 'exit' and item['exit_code'] is not None:
            child_code = item['exit_code']
            if child_code < 0 or child_code in (130, 143) or child_code >= 0x80000000:
                outcome = 'cancelled' if child_code in (-signal.SIGINT, -signal.SIGTERM, 130, 143) else 'process_crash'
                exit_code = 128 - child_code if child_code < 0 else child_code
                break
        if item['reason'] == 'exit' and item['exit_code'] == 0:
            outcome, exit_code = 'success', 0; break
        exit_code = 124 if item['reason'] == 'attempt_timeout' else (item['exit_code'] or 1)
        retryable = (item['reason'] in ('exit', 'attempt_timeout') and not item['permanent'] and
                     (bool(item['network']) or item['reason'] == 'attempt_timeout'))
        if not retryable or index + 1 == attempts:
            break
        delay = delays[min(index, len(delays) - 1)]
        if time.monotonic() - start + delay >= total_timeout:
            outcome, exit_code = 'budget_exhausted', 124; break
        emit(f'[pub-get] retryable dependency failure; wait_seconds={delay}')
        until = time.monotonic() + delay
        while time.monotonic() < until and not cancelled():
            time.sleep(min(.05, max(0, until - time.monotonic())))
    return max(1, min(255, exit_code)) if exit_code else 0, {
        'schema_version': 1, 'outcome': outcome, 'exit_code': max(1, min(255, exit_code)) if exit_code else 0, 'attempt_limit': attempts,
        'attempt_timeout_seconds': attempt_timeout, 'total_timeout_seconds': total_timeout,
        'elapsed_seconds': round(time.monotonic() - start, 3), 'attempts': records}


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise OSError('report_symlink_rejected')
    fd, temporary = tempfile.mkstemp(prefix='.pub-get-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(report, stream, indent=2); stream.write('\n')
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool', choices=('flutter', 'dart'), required=True)
    parser.add_argument('--cwd', type=Path, default=Path.cwd())
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args(argv)
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(errors='backslashreplace')
    executable = shutil.which(args.tool)
    if not executable:
        print('[pub-get] requested tool not found', file=sys.stderr); return 127
    # Prevent cmd.exe metacharacters in a Windows batch launcher path. Arguments
    # are fixed literals; no workflow input can supply shell text or build flags.
    if IS_WINDOWS and re.search(r'[&|<>^%!\r\n"]', executable):
        print('[pub-get] unsafe launcher path', file=sys.stderr); return 2
    cancelled_signal = [0]
    old = {}
    def cancel(signum, frame):
        cancelled_signal[0] = signum
    for sig in (signal.SIGINT, signal.SIGTERM):
        old[sig] = signal.signal(sig, cancel)
    try:
        code, report = execute([executable, 'pub', 'get'], args.cwd, os.environ,
                               cancelled=lambda: cancelled_signal[0],
                               emit=lambda line: print(line, flush=True))
        report['tool'] = args.tool
        write_report(args.report, report)
        print('[pub-get] outcome=' + report['outcome'] + '; attempts=' + str(len(report['attempts'])))
        return code
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--worker':
        raise SystemExit(worker(json.loads(sys.argv[2])))
    try:
        raise SystemExit(main())
    except (OSError, ValueError):
        print('[pub-get] wrapper failed; no retry', file=sys.stderr)
        raise SystemExit(125)
