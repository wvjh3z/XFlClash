#!/usr/bin/env python3
"""Run a prepared pure-Dart tool without dispatching application native hooks."""
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname

ENTRIES = {'build_runner': 'build_runner.dart', 'flutter_launcher_icons': 'flutter_launcher_icons.dart', 'test': 'test.dart'}


def command(package, arguments, *, root=None, flutter=None):
    if package not in ENTRIES:
        raise ValueError('unsupported_pure_dart_tool')
    root = (root or Path.cwd()).resolve()
    graph = root/'.dart_tool/package_config.json'
    data = json.loads(graph.read_text(encoding='utf-8'))
    matches = [entry for entry in data['packages'] if entry['name'] == package]
    if len(matches) != 1:
        raise ValueError('tool_missing_from_prepared_package_graph')
    uri = urlparse(urljoin(graph.as_uri(), matches[0]['rootUri']))
    if uri.scheme != 'file' or uri.netloc:
        raise ValueError('tool_requires_local_package_graph')
    source = Path(url2pathname(uri.path))/'bin'/ENTRIES[package]
    sdk = flutter or Path(os.environ['FLUTTER_ROOT'])
    dart = sdk/('bin/cache/dart-sdk/bin/dart.exe' if os.name == 'nt' else 'bin/cache/dart-sdk/bin/dart')
    if not dart.is_file() or not source.is_file():
        raise ValueError('prepared_dart_tool_input_missing')
    return [str(dart), '--packages='+str(graph), str(source), *arguments]


def main():
    try:
        if len(sys.argv) < 2:
            raise ValueError('pure_dart_tool_required')
        return subprocess.run(command(sys.argv[1], sys.argv[2:])).returncode
    except (OSError, ValueError, KeyError) as error:
        print('Pure Dart tool failed: '+type(error).__name__, file=sys.stderr)
        return 1


if __name__ == '__main__': raise SystemExit(main())
