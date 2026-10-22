#!/usr/bin/env python3
"""Prepare an isolated unlocked Secret Service before the Linux smoke driver."""
import os
from pathlib import Path
import subprocess
import sys


def main() -> None:
    root = Path(os.environ['XB_NATIVE_SMOKE_DIR']).resolve()
    for key in ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR']:
        if not Path(os.environ[key]).resolve().is_relative_to(root):
            raise RuntimeError(f'{key} must be inside the smoke batch')
    documents = subprocess.check_output(['xdg-user-dir', 'DOCUMENTS'], text=True, timeout=10).strip()
    if Path(documents).resolve() != root / 'documents':
        raise RuntimeError('Documents must resolve inside the smoke batch')
    if not os.environ.get('DBUS_SESSION_BUS_ADDRESS'):
        raise RuntimeError('Run inside the owned dbus-run-session')
    subprocess.run(
        ['gnome-keyring-daemon', '--unlock', '--components=secrets'],
        input=b'local-native-smoke-fixture\n', check=True, timeout=20,
    )
    result = subprocess.run(
        ['gdbus', 'call', '--session', '--dest', 'org.freedesktop.secrets',
         '--object-path', '/org/freedesktop/secrets/collection/login',
         '--method', 'org.freedesktop.DBus.Properties.Get',
         'org.freedesktop.Secret.Collection', 'Locked'],
        capture_output=True, text=True, check=True, timeout=15,
    )
    if 'false' not in result.stdout:
        raise RuntimeError('The isolated login keyring is not unlocked')
    print('Isolated fixture keyring ready', flush=True)
    os.execvpe(sys.argv[1], sys.argv[1:], os.environ)


if __name__ == '__main__':
    main()
