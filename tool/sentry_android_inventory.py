"""Offline, credential-free APK ELF inventory. Never executes packaged code."""
import re
import shutil
import tempfile
import zipfile
from pathlib import Path

from sentry_elf import inspect_elf, ElfError

ARCHES = {'armeabi-v7a': 'arm', 'arm64-v8a': 'aarch64', 'x86_64': 'x86_64'}
REQUIRED = {'libclash.so', 'librust_api.so'}
SYMBOL_REQUIRED = REQUIRED | {'libsentry.so', 'libsentry-android.so'}


def inventory(packages, expected_abis=()):
    rows, errors, found = [], [], set()
    for index, package in enumerate(packages):
        # Only conventional public distribution filenames enter the report.
        label = package.name if re.fullmatch(r'[A-Za-z0-9_.-]+\.apk', package.name) else f'package-{index}.apk'
        def issue(code, **fields):
            errors.append(dict(code=code, package=label, package_index=index, **fields))
        with zipfile.ZipFile(package) as archive, tempfile.TemporaryDirectory(prefix='apk-elf-audit-') as tmp:
            names = [item.filename for item in archive.infolist()]
            if len(names) != len(set(names)):
                issue('duplicate_apk_entries')
                continue
            groups = {}
            for item in archive.infolist():
                match = re.fullmatch(r'lib/([^/]+)/([A-Za-z0-9_.-]+\.so)', item.filename)
                if match and match[1] in ARCHES:
                    groups.setdefault(match[1], []).append((item, match[2]))
            for abi, entries in groups.items():
                modules = {name for _, name in entries}
                if not modules & {'libapp.so', 'libflutter.so'}:
                    continue
                found.add(abi)
                for missing in sorted(REQUIRED - modules):
                    issue('required_apk_native_module_missing', abi=abi, module=missing)
                for item, name in entries:
                    if item.file_size > 512 * 1024 * 1024:
                        issue('oversize_apk_native_module', abi=abi, module=name)
                        continue
                    binary = Path(tmp) / 'module.elf'
                    with archive.open(item) as source, binary.open('wb') as out:
                        shutil.copyfileobj(source, out)
                    try:
                        info = inspect_elf(binary)
                    except (ElfError, OSError):
                        issue('invalid_native_elf', abi=abi, module=name)
                        continue
                    row = dict(package=label, package_index=index, abi=abi, module=name,
                               expected_architecture=ARCHES[abi], actual_architecture=info['architecture'],
                               build_id=info['build_id'])
                    rows.append(row)
                    if info['architecture'] != ARCHES[abi]:
                        issue('runtime_architecture_mismatch', **{k: v for k, v in row.items() if k not in ('package', 'package_index')})
                    elif name in SYMBOL_REQUIRED and not info['build_id']:
                        issue('runtime_build_id_missing', abi=abi, module=name)
    if not found:
        errors.append(dict(code='flutter_runtime_abi_missing'))
    if expected_abis and found != set(expected_abis):
        errors.append(dict(code='runtime_abi_set_mismatch', expected=sorted(set(expected_abis)), actual=sorted(found)))
    return dict(schema_version=1, platform='android', status='failed' if errors else 'audited',
                modules=rows, errors=errors)
