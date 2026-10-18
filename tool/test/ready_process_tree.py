"""Test-only parent/descendant readiness and independent termination witness.

Loopback sockets stay open until the fixture process exits. Ready + ping proves
both processes ran; EOF proves cleanup did more than remove an uncreated marker.
No production process API or timeout is changed.
"""
from pathlib import Path
import socket
import sys
import threading
import time

STARTUP_TIMEOUT = 15
FIXTURE_SOURCE = '''import os, socket, subprocess, sys, time
role, host, port, delay = sys.argv[1:]
time.sleep(float(delay))
connection = socket.create_connection((host, int(port)), timeout=15)
connection.settimeout(None)
if role == "parent":
    descendant = subprocess.Popen([sys.executable, __file__, "child", host, port, delay])
connection.sendall((role + "\\n").encode("ascii"))
while True:
    command = connection.recv(1)
    if command == b"P":
        connection.sendall(b"A")
    elif command == b"X" or not command:
        # Avoid a Popen finalizer warning when intentionally leaving the child
        # alive for the parent's-exit cleanup regression.
        os._exit(7 if role == "parent" else 0)
    else:
        os._exit(9)
'''


class ReadyTree:
    def __init__(self, directory, *, startup_delay=0):
        self.script = Path(directory) / 'ready tree.py'
        self.script.write_text(FIXTURE_SOURCE, encoding='utf-8')
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(2)
        self.listener.settimeout(.1)
        self.port = self.listener.getsockname()[1]
        self.command = [sys.executable, str(self.script), 'parent', '127.0.0.1', str(self.port), str(startup_delay)]
        self.connections = {}
        self.failure = None
        self.ready = threading.Event()
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._receive, daemon=True)
        self.thread.start()

    def _receive(self):
        deadline = time.monotonic() + STARTUP_TIMEOUT
        pending = None
        try:
            while len(self.connections) < 2 and not self.stopped.is_set():
                if time.monotonic() >= deadline:
                    raise TimeoutError('parent/descendant readiness deadline expired')
                try:
                    pending, _ = self.listener.accept()
                except socket.timeout:
                    continue
                pending.settimeout(max(.1, deadline - time.monotonic()))
                name = b''
                while not name.endswith(b'\n') and len(name) < 16:
                    value = pending.recv(1)
                    if not value:
                        raise AssertionError('process exited before readiness message')
                    name += value
                role = name.decode('ascii').strip()
                if role not in {'parent', 'child'} or role in self.connections:
                    raise AssertionError('invalid fixture readiness')
                self.connections[role] = pending
                pending = None
            if len(self.connections) == 2:
                self.ready.set()
        except Exception as error:
            if not self.stopped.is_set():
                self.failure = error
                self.ready.set()
        finally:
            if pending is not None:
                pending.close()

    def is_ready(self):
        if self.failure is not None:
            raise AssertionError('fixture failed before both processes were ready') from self.failure
        return self.ready.is_set()

    def wait_ready(self):
        if not self.ready.wait(STARTUP_TIMEOUT + 1) or not self.is_ready():
            raise AssertionError('fixture never confirmed parent and descendant readiness')

    def assert_alive(self):
        self.wait_ready()
        for role, connection in self.connections.items():
            connection.settimeout(3)
            connection.sendall(b'P')
            if connection.recv(1) != b'A':
                raise AssertionError(role + ' did not acknowledge liveness probe')

    def exit_parent(self):
        self.connections['parent'].sendall(b'X')

    def assert_closed(self, *, timeout=3):
        if not self.is_ready() or set(self.connections) != {'parent', 'child'}:
            raise AssertionError('cannot claim termination without readiness')
        for role, connection in self.connections.items():
            connection.settimeout(timeout)
            try:
                value = connection.recv(1)
            except ConnectionResetError:
                value = b''  # Windows may reset sockets when TerminateJobObject kills owners.
            except socket.timeout as error:
                raise AssertionError(role + ' is still holding the readiness socket') from error
            if value:
                raise AssertionError(role + ' sent unexpected data instead of closing')

    def close(self):
        if self.stopped.is_set():
            return
        self.stopped.set()
        self.listener.close()
        self.thread.join(timeout=STARTUP_TIMEOUT + 1)
        for connection in self.connections.values():
            try:
                connection.sendall(b'X')
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        if self.thread.is_alive():
            raise AssertionError('fixture readiness thread did not stop')

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
