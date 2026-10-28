#!/usr/bin/env python3
"""Best-effort local build diagnostics; never replace the build's exit status."""
import argparse
from pathlib import Path
import sys
import tempfile
from native_hook_diagnostics import collect
from pub_get_retry import write_report


def create_session(root):
    parent = Path(root) / '.local-build/desktop-diagnostics'
    parent.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix='run-', dir=parent)).resolve()


def finalize(root, destination, exit_code):
    destination = Path(destination)
    summary = {'main_exit_code': exit_code, 'diagnostics_complete': False}
    try:
        value = collect(root, report=destination / 'native-hook-diagnostics.json')
        summary['hook_status'] = value['status']
        summary['diagnostics_complete'] = value['status'] == 'complete'
    except BaseException as error:
        summary['failure_type'] = type(error).__name__
        print('Build diagnostics collection failed; original build status retained', file=sys.stderr)
    try:
        write_report(destination / 'finalization.json', summary)
    except BaseException:
        print('Build diagnostics report could not be saved; original build status retained', file=sys.stderr)
    return exit_code


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', newline='\n')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--create-session', action='store_true')
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--exit-code', type=int, default=0)
    args = parser.parse_args()
    if args.create_session:
        print(create_session(args.root))
    elif args.destination is None:
        parser.error('--destination required')
    else:
        finalize(args.root, args.destination, args.exit_code)
