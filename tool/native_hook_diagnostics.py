#!/usr/bin/env python3
"""Preserve hook change markers with explicit complete/partial/missing status."""
import json
from pathlib import Path
import os
from pub_get_retry import write_report


def collect(root, *, report=None):
    root = Path(root).resolve()
    report = Path(report) if report is not None else root / 'build/native-hook-diagnostics.json'
    result = {'schema_version': 2, 'status': 'missing', 'collected': False,
              'files_scanned': 0, 'changed_inputs': [], 'read_errors': 0,
              'errors': []}
    write_report(report, result)
    base = root / '.dart_tool/hooks_runner'

    def error(kind):
        result['read_errors'] += 1
        result['errors'].append(kind)  # No raw exception or environment content.

    if base.is_symlink():
        error('root_symlink')
    else:
        try:
            exists = base.stat()  # Unlike exists(), preserve access failures.
        except FileNotFoundError:
            exists = None
        except OSError:
            exists = None
            error('root_access')
        if exists is not None:
            if not base.is_dir():
                error('root_not_directory')
            else:
                for directory, dirs, files in os.walk(
                        base, followlinks=False, onerror=lambda _: error('traversal')):
                    for name in dirs[:]:
                        if (Path(directory) / name).is_symlink():
                            dirs.remove(name)
                            error('directory_symlink')
                    for name in files:
                        if 'dependenc' not in name or not name.endswith('.json'):
                            continue
                        p = Path(directory) / name
                        try:
                            if p.is_symlink() or p.stat().st_size > 8 * 1024 * 1024:
                                raise ValueError('unsafe')
                            data = json.loads(p.read_text(encoding='utf-8'))
                            entries = data.get('file_system') if isinstance(data, dict) else None
                            if not isinstance(entries, list):
                                raise ValueError('schema')
                            changes = []
                            for entry in entries:
                                if (not isinstance(entry, dict) or
                                        type(entry.get('hash')) is not int or
                                        not isinstance(entry.get('path'), str)):
                                    raise ValueError('entry_schema')
                                if entry['hash'] != 1:
                                    continue
                                value = Path(entry['path'])
                                if not value.is_absolute():
                                    value = root / value
                                try:
                                    label = value.relative_to(root).as_posix()
                                except ValueError:
                                    label = '<external>/' + '/'.join(value.parts[-4:])
                                changes.append({'record': p.relative_to(root).as_posix(), 'path': label})
                            result['changed_inputs'].extend(changes)
                            result['files_scanned'] += 1
                        except (OSError, ValueError):
                            error('record_read_or_schema')
    result['status'] = ('partial' if result['read_errors'] else
                        'complete' if result['files_scanned'] else 'missing')
    result['collected'] = result['status'] == 'complete'
    write_report(report, result)
    return result


if __name__ == '__main__':
    value = collect(Path(__file__).resolve().parents[1])
    print('Hook diagnostics status=' + value['status'] +
          ' records=' + str(value['files_scanned']) +
          ' changed=' + str(len(value['changed_inputs'])) +
          ' read_errors=' + str(value['read_errors']))
