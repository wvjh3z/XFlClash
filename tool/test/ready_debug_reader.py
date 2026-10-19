"""POSIX test fixture: independent readiness sockets and real stdout ownership."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

from owned_process_cleanup import cleanup_owned_group

STARTUP_TIMEOUT = 15
SOURCE = r'''import os, socket, subprocess, sys, time
mode, parent_fd, child_fd, delay = sys.argv[1:]
time.sleep(float(delay))
if mode == 'child':
    control = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, fileno=int(child_fd))
else:
    control = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, fileno=int(parent_fd))
    if mode == 'held':
        # The child inherits stdout and the same process group, but owns a
        # separate control socket. No other process retains that socket end.
        subprocess.Popen([sys.executable, __file__, 'child', '-1', child_fd, delay],
                         pass_fds=(int(child_fd),))
        os.close(int(child_fd))
    else:
        os.close(1)
control.sendall(b'R')
while True:
    command = control.recv(1)
    if command == b'P':
        control.sendall(b'A')
    elif command == b'X' or not command:
        os._exit(0)
    else:
        os._exit(9)
'''


class OffsetClock:
    """Advance only the reader's clock; subprocess/cleanup retain real time."""
    def __init__(self):
        self.offset = 0

    def monotonic(self):
        return time.monotonic() + self.offset

    def advance(self, seconds):
        self.offset += seconds


class ReadyReader:
    def __init__(self, directory, mode, *, startup_delay=0, startup_timeout=STARTUP_TIMEOUT):
        if mode not in {'eof', 'held'}:
            raise ValueError('Unknown reader fixture mode')
        self.mode = mode
        self.startup_delay = startup_delay
        self.startup_timeout = startup_timeout
        self.script = Path(directory) / 'ready reader.py'
        self.script.write_bytes(SOURCE.encode('utf-8'))
        self.process = None
        self.controls = {}
        self.ready = set()
        self.verified_closed = False
        self.parent_exited = False

    def __enter__(self):
        peers = []
        try:
            parent, peer = socket.socketpair()
            self.controls['parent'] = parent; peers.append(peer)
            child_fd = -1
            if self.mode == 'held':
                child, child_peer = socket.socketpair()
                self.controls['child'] = child; peers.append(child_peer)
                child_fd = child_peer.fileno()
            deadline = time.monotonic() + self.startup_timeout
            self.process = subprocess.Popen(
                [sys.executable, str(self.script), self.mode, str(peer.fileno()),
                 str(child_fd), str(self.startup_delay)],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                pass_fds=tuple(p.fileno() for p in peers), start_new_session=True)
            for p in peers:
                p.close()
            for role, connection in self.controls.items():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError('Reader readiness deadline expired')
                connection.settimeout(remaining)
                try:
                    value = connection.recv(1)
                except socket.timeout as error:
                    raise AssertionError('Reader readiness deadline expired') from error
                if value != b'R':
                    raise AssertionError('Reader exited before readiness')
                self.ready.add(role)
            self.assert_alive()
            return self
        except BaseException:
            self.close()
            raise
        finally:
            for p in peers:
                p.close()

    def assert_alive(self, roles=None):
        for role in roles or self.controls:
            if role not in self.ready:
                raise AssertionError('Reader liveness requires readiness')
            connection = self.controls[role]
            connection.settimeout(3)
            connection.sendall(b'P')
            if connection.recv(1) != b'A':
                raise AssertionError('Reader did not acknowledge liveness')

    def exit_parent(self):
        self.assert_alive()
        self.controls['parent'].sendall(b'X')
        if self.process.wait(timeout=STARTUP_TIMEOUT) != 0:
            raise AssertionError('Fixture parent exit failed')
        self.parent_exited = True
        self.assert_alive(('child',))

    def assert_closed(self, *, timeout=3):
        if not self.ready or self.ready != set(self.controls):
            raise AssertionError('Cannot claim cleanup without readiness')
        for connection in self.controls.values():
            connection.settimeout(timeout)
            try:
                value = connection.recv(1)
            except ConnectionResetError:
                value = b''
            except socket.timeout as error:
                raise AssertionError('Reader process is still alive after cleanup') from error
            if value:
                raise AssertionError('Unexpected data instead of process termination')
        if self.process.poll() is None:
            raise AssertionError('Reader parent was not reaped')
        self.verified_closed = True

    def evidence(self):
        return {'parent_ready': 'parent' in self.ready, 'child_ready': 'child' in self.ready,
                'parent_exited': self.parent_exited, 'termination_witnessed': self.verified_closed}

    def close(self):
        try:
            if self.process is not None and not self.verified_closed:
                # Independent fallback after a failed assertion or cleanup
                # mutant. Never leave a process alive to make a negative pass.
                cleanup_owned_group(self.process)
        finally:
            if self.process is not None and self.process.stdout is not None:
                self.process.stdout.close()
            for connection in self.controls.values():
                connection.close()

    def __exit__(self, *_):
        self.close()
