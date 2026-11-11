#!/usr/bin/env python3
"""Bounded Ubuntu package preparation for the two Linux CI targets.

Use signed, architecture-matched Canonical archives in temporary APT lists.
Only index/package downloads can fail over; dpkg installation is never retried.
No resolver, system source list, signing policy or runner release is changed.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

from pub_get_retry import execute, write_report as _write_report

KEYRING = '/usr/share/keyrings/ubuntu-archive-keyring.gpg'
TARGETS = {'amd64': ('22.04', 'jammy'), 'arm64': ('24.04', 'noble')}
COMMON_PACKAGES = (
    'xvfb', 'dbus-daemon', 'ninja-build', 'libgtk-3-dev',
    'libayatana-appindicator3-dev', 'libkeybinder-3.0-dev', 'locate', 'file',
    'squashfs-tools', 'libwebkit2gtk-4.1-dev', 'libsoup-3.0-dev',
    'libcurl4-openssl-dev', 'libsecret-1-dev', 'libjsoncpp-dev', 'patchelf',
)
PHASE_TIMEOUTS = {'update': 120, 'download': 240, 'install': 240}
TOTAL_TIMEOUT = 840  # Leave the existing 15-minute workflow limit room for cleanup.
PERMANENT = {
    'signature': r'NO_PUBKEY|EXPKEYSIG|BADSIG|not signed|signatures? couldn.t be verified|invalid signature|signatures were invalid|clearsigned file isn.t valid|NOSPLIT',
    'integrity': r'hash sum mismatch|size mismatch|unexpected size|checksum mismatch',
    'repository': r'does not have a Release file|no Release file|Release file.*(?:not valid yet|expired)|malformed|conflicting values|404\s+Not Found',
    'package': r'unable to locate package|no installation candidate|unmet dependencies|held broken packages',
    'local_state': r'could not get lock|unable to acquire.*lock|dpkg was interrupted|no space left|read.only file system',
    'certificate': r'certificate verification failed|certificate verify failed|certificate is not trusted|certificate has expired',
    'authorization': r'401\s+Unauthorized|403\s+Forbidden|407\s+Proxy',
}
NETWORK = {
    'dns': r'temporary failure resolving|could not resolve|temporary failure in name resolution',
    'connection': r'connection (?:failed|timed out|reset|refused)|could not connect|network is unreachable|connection timed out',
    'server': r'\b(?:429|500|502|503|504)\s+(?:Too Many Requests|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)',
}
INDEX_FAILURE = re.compile(r'failed to fetch|some index files failed to download', re.I)


def write_report(path, data):
    _write_report(Path(path), data)
    # The installer runs as root; upload-artifact runs as the runner user.
    # Reports contain only public package/profile names and closed-set diagnostics.
    Path(path).chmod(0o644)


def packages_for(arch):
    if arch not in TARGETS:
        raise ValueError('Unsupported Linux package target')
    return COMMON_PACKAGES + (('libfuse2', 'rpm') if arch == 'amd64' else ('libfuse2t64',))


def source_text(arch, mirror):
    """Both profiles are Canonical-owned HTTPS archives with the same Ubuntu keyring."""
    _, suite = TARGETS[arch]
    if mirror not in ('canonical', 'azure'):
        raise ValueError('Unknown archive profile')
    if arch == 'amd64':
        archive = 'https://archive.ubuntu.com/ubuntu' if mirror == 'canonical' else 'https://azure.archive.ubuntu.com/ubuntu'
        security = 'https://security.ubuntu.com/ubuntu' if mirror == 'canonical' else archive
    else:
        archive = 'https://ports.ubuntu.com/ubuntu-ports' if mirror == 'canonical' else 'https://azure.ports.ubuntu.com/ubuntu-ports'
        security = archive
    def stanza(uri, suites):
        return (f'Types: deb\nURIs: {uri}\nSuites: {suites}\n'
                f'Components: main restricted universe multiverse\nArchitectures: {arch}\n'
                f'Signed-By: {KEYRING}\n')
    return stanza(archive, f'{suite} {suite}-updates {suite}-backports') + '\n' + stanza(security, f'{suite}-security')


def apt_command(phase, folder, arch):
    command = [
        'apt-get', '-o', f'Dir::Etc::sourcelist={folder / "ubuntu.sources"}',
        '-o', 'Dir::Etc::sourceparts=-', '-o', f'Dir::State::lists={folder / "lists"}',
        '-o', f'Dir::Cache::archives={folder / "archives"}',
        '-o', 'Dir::Cache::pkgcache=', '-o', 'Dir::Cache::srcpkgcache=',
        '-o', 'Acquire::Languages=none',
        '-o', 'APT::Update::Error-Mode=any',
        '-o', 'Acquire::Retries=0', '-o', 'Acquire::http::Timeout=15',
        '-o', 'Acquire::https::Timeout=15',
    ]
    if phase == 'update':
        return command + ['update']
    if phase not in ('download', 'install'):
        raise ValueError('Unknown APT phase')
    return command + ['-y', '--download-only' if phase == 'download' else '--no-download', 'install', *packages_for(arch)]


class AptOutput:
    def __init__(self, emit):
        self.emit = emit
        self.permanent = set()
        self.network = set()
        self.index_failed = False

    def __call__(self, line):
        # execute() already bounds output, masks secrets and neutralizes Actions commands.
        for name, pattern in PERMANENT.items():
            if re.search(pattern, line, re.I):
                self.permanent.add(name)
        for name, pattern in NETWORK.items():
            if re.search(pattern, line, re.I):
                self.network.add(name)
        self.index_failed |= bool(INDEX_FAILURE.search(line))
        self.emit(line.replace('[pub-get output]', '[linux-apt output]').replace('[pub-get]', '[linux-apt]'))


def install(arch, report_path, *, runner=execute, environment=None, clock=time.monotonic,
            cancelled=lambda: 0, emit=print, total_timeout=TOTAL_TIMEOUT):
    packages = packages_for(arch)
    environment = {**(os.environ if environment is None else environment),
                   'LC_ALL': 'C', 'DEBIAN_FRONTEND': 'noninteractive'}
    report_path = Path(report_path)
    report = {'schema_version': 1, 'passed': False, 'outcome': 'running', 'arch': arch,
              'ubuntu_version': TARGETS[arch][0], 'suite': TARGETS[arch][1], 'packages': list(packages),
              'total_timeout_seconds': total_timeout, 'phase_timeouts': PHASE_TIMEOUTS,
              'system_sources_changed': False, 'resolver_changed': False,
              'signature_checks_disabled': False, 'attempts': []}
    start = clock()
    write_report(report_path, report)

    def finish(outcome, code):
        if code == 0 and cancelled():
            outcome, code = 'cancelled', 128 + cancelled()
        report.update(outcome=outcome, passed=code == 0, exit_code=code,
                      elapsed_seconds=round(clock() - start, 3))
        write_report(report_path, report)
        return code, report

    with tempfile.TemporaryDirectory(prefix='xflclash-linux-apt-') as temporary:
        root = Path(temporary)
        root.chmod(0o755)  # _apt must traverse this public-metadata-only directory.
        for mirror in ('canonical', 'azure'):
            folder = root / mirror
            folder.mkdir(mode=0o755)
            folder.chmod(0o755)
            for child in ('lists', 'archives'):
                (folder / child).mkdir(mode=0o755)
                (folder / child).chmod(0o755)
            sources = folder / 'ubuntu.sources'
            sources.write_text(source_text(arch, mirror), encoding='utf-8')
            sources.chmod(0o644)
            for phase in ('update', 'download', 'install'):
                if cancelled():
                    return finish('cancelled', 128 + cancelled())
                remaining = total_timeout - (clock() - start)
                if remaining <= 0:
                    return finish('budget_exhausted', 124)
                limit = min(PHASE_TIMEOUTS[phase], remaining)
                emit(f'[linux-apt] profile={mirror} phase={phase} budget_seconds={int(limit)}')
                output = AptOutput(emit)
                code, details = runner(apt_command(phase, folder, arch), folder, environment,
                                       attempts=1, attempt_timeout=limit, total_timeout=limit,
                                       emit=output, cancelled=cancelled)
                raw = details.get('attempts', [])
                record = {'profile': mirror, 'phase': phase, 'exit_code': code,
                          'process': details, 'permanent': sorted(output.permanent),
                          'network': sorted(output.network), 'index_failed': output.index_failed}
                report['attempts'].append(record)
                if code == 0 and (output.permanent or phase == 'update' and output.index_failed):
                    # Ubuntu apt-get can historically return0 after partial index failure.
                    code = 100
                    record.update(exit_code=code, soft_index_failure=phase == 'update' and output.index_failed)
                write_report(report_path, report)
                if cancelled() or details.get('outcome') == 'cancelled':
                    return finish('cancelled', code if code in (130, 143) else 128 + (cancelled() or signal.SIGINT))
                if code == 0:
                    continue
                permanent = output.permanent or any(item.get('permanent') for item in raw)
                network = output.network or any(item.get('network') for item in raw)
                timeout = any(item.get('reason') == 'attempt_timeout' for item in raw)
                cleaned = all(item.get('cleanup_succeeded', False) for item in raw)
                if (phase != 'install' and mirror == 'canonical' and cleaned and not permanent
                        and (network or timeout) and details.get('outcome') not in ('process_crash', 'cleanup_failed')):
                    emit('[linux-apt] retrying dependency downloads with the alternate Canonical archive')
                    break
                return finish('failed', code)
            else:
                return finish('success', 0)
    return finish('failed', 1)


def validate_host(arch):
    fields = {}
    for line in Path('/etc/os-release').read_text(encoding='utf-8').splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            fields[key] = ' '.join(shlex.split(value))
    version, suite = TARGETS[arch]
    actual_arch = subprocess.check_output(['dpkg', '--print-architecture'], text=True, timeout=10).strip()
    if fields.get('ID') != 'ubuntu' or fields.get('VERSION_ID') != version or fields.get('VERSION_CODENAME') != suite or actual_arch != arch:
        raise RuntimeError('Runner distribution or architecture differs from the fixed Linux matrix')
    if os.geteuid() != 0 or not Path(KEYRING).is_file():
        raise RuntimeError('Root and the installed Ubuntu archive keyring are required')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=TARGETS, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args(argv)
    write_report(args.report, {'schema_version': 1, 'passed': False, 'outcome': 'validating_host', 'arch': args.arch})
    cancelled = [0]
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        for sig in handlers:
            signal.signal(sig, lambda received, _frame: cancelled.__setitem__(0, received))
        validate_host(args.arch)
        code, _ = install(args.arch, args.report, cancelled=lambda: cancelled[0])
        return code
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        # Categories only: no environment or user-provided path is exposed in diagnostics.
        write_report(args.report, {'schema_version': 1, 'passed': False, 'outcome': 'preparation_error',
                                  'arch': args.arch, 'error_type': type(error).__name__})
        print('[linux-apt] preparation failed: ' + type(error).__name__, file=sys.stderr)
        return 1
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    raise SystemExit(main())
