#!/usr/bin/env python3
"""Read final Linux packages without installing/executing them; bind ELF bytes to bundle."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import sys
import subprocess
import tarfile
import tempfile


class PackageError(RuntimeError):
    pass


def safe_name(raw):
    name = raw.removeprefix('./')
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or '\\' in name or '\x00' in name:
        raise PackageError('unsafe_package_path')
    return name


def cpio_members(stream):
    """Read newc records; never materialize archive links or execute scriptlets."""
    def exact(size):
        if not 0 <= size <= 512 * 1024 * 1024:
            raise PackageError('unsafe_cpio_size')
        data = stream.read(size)
        if len(data) != size:
            raise PackageError('truncated_cpio')
        return data
    while True:
        header = exact(110)
        if header[:6] not in (b'070701', b'070702'):
            raise PackageError('unsupported_cpio')
        try:
            values = [int(header[i:i+8], 16) for i in range(6, 110, 8)]
        except ValueError as error:
            raise PackageError('invalid_cpio_header') from error
        size, namesize = values[6], values[11]
        if not 1 <= namesize <= 4096:
            raise PackageError('unsafe_cpio_name')
        name = exact(namesize)
        if name[-1:] != b'\0':
            raise PackageError('invalid_cpio_name')
        name = safe_name(name[:-1].decode('utf-8'))
        exact(-(110 + namesize) % 4)
        data = exact(size)
        exact(-size % 4)
        if name == 'TRAILER!!!':
            return
        yield name, values[1], data


def run(command, **kwargs):
    result = subprocess.run([str(v) for v in command], stderr=subprocess.PIPE,
                            timeout=180, check=False, **kwargs)
    if result.returncode:
        error = PackageError('package_reader_failed:' + Path(command[0]).name)
        error.exit_code = result.returncode
        raise error
    return result


def expected_modules(bundle):
    result = {}
    for path in sorted(bundle.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        result[path.relative_to(bundle).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not {'FlClash', 'FlClashCore', 'FlClashHelperService'} <= result.keys():
        raise PackageError('missing_bundle_runners')
    return result


def verify_members(members, prefix, expected, launcher=None):
    seen = set()
    launcher_seen = False
    for name, mode, data in members:
        name = safe_name(name)
        if launcher is not None and name == launcher[0]:
            if launcher_seen or not stat.S_ISLNK(mode) or data.decode('utf-8') != launcher[1]:
                raise PackageError('invalid_packaged_launcher')
            launcher_seen = True
        if not name.startswith(prefix):
            continue
        relative = name[len(prefix):]
        if relative not in expected:
            if stat.S_ISREG(mode) and data.startswith(b'\x7fELF'):
                raise PackageError('unexpected_packaged_native_module')
            continue
        if relative in seen or not stat.S_ISREG(mode):
            raise PackageError('duplicate_or_linked_native_module')
        seen.add(relative)
        if hashlib.sha256(data).hexdigest() != expected[relative]:
            raise PackageError('packaged_native_bytes_changed:' + relative)
        if '/' not in relative and not mode & 0o111:
            raise PackageError('packaged_runner_not_executable')
    if launcher is not None and not launcher_seen:
        raise PackageError('missing_packaged_launcher')
    if seen != expected.keys():
        raise PackageError('missing_packaged_native_module')


def appimage_payload_offset(package, architecture):
    """Read the pinned type-2 ELF/SquashFS boundary without executing the image."""
    with Path(package).open('rb') as stream:
        header = stream.read(64)
        if (len(header) != 64 or header[:7] != b'\x7fELF\x02\x01\x01'
                or header[8:11] != b'AI\x02'):
            raise PackageError('invalid_appimage_container')
        machine = struct.unpack_from('<H', header, 18)[0]
        if machine != {'amd64': 62, 'arm64': 183}[architecture]:
            raise PackageError('appimage_architecture_mismatch')
        section_offset = struct.unpack_from('<Q', header, 40)[0]
        header_size = struct.unpack_from('<H', header, 52)[0]
        entry_size, count = struct.unpack_from('<HH', header, 58)
        offset = section_offset + entry_size * count
        stream.seek(0, 2)
        size = stream.tell()
        if header_size != 64 or section_offset < 64 or entry_size != 64 or not count or offset + 96 > size:
            raise PackageError('invalid_appimage_boundary')
        stream.seek(offset)
        if stream.read(4) != b'hsqs':
            raise PackageError('invalid_appimage_squashfs')
    return offset


def verify_appimage(package, expected, architecture):
    offset = appimage_payload_offset(package, architecture)
    for name, digest in expected.items():
        data = run(['unsquashfs', '-offset', str(offset), '-cat', package, name], stdout=subprocess.PIPE).stdout
        if hashlib.sha256(data).hexdigest() != digest:
            raise PackageError('packaged_native_bytes_changed:' + name)
    return offset


def verify(context, dist=Path('dist'), build=Path('build'), *, report_path=None):
    # Write a fresh, bounded diagnostic even if failure precedes the first package.
    from release_pipeline import write_json
    build, dist = Path(build), Path(dist)
    report_path = Path(report_path) if report_path is not None else build/'linux-package-audit.json'
    audit = {'schema_version': 1, 'passed': False, 'stage': 'bundle', 'format': None, 'packages': []}
    write_json(report_path, audit)
    try:
        records = _verify(context, dist, build, audit)
    except Exception as error:
        codes = {
            'unsafe_package_path', 'unsafe_cpio_size', 'truncated_cpio', 'unsupported_cpio',
            'invalid_cpio_header', 'unsafe_cpio_name', 'invalid_cpio_name', 'package_reader_failed',
            'missing_bundle_runners', 'invalid_packaged_launcher', 'unexpected_packaged_native_module',
            'duplicate_or_linked_native_module', 'packaged_native_bytes_changed',
            'packaged_runner_not_executable', 'missing_packaged_launcher', 'missing_packaged_native_module',
            'ambiguous_linux_package', 'rpm_version_mismatch', 'deb_version_mismatch', 'unsafe_tar_size',
            'invalid_appimage_container', 'appimage_architecture_mismatch',
            'invalid_appimage_boundary', 'invalid_appimage_squashfs',
        }
        code, _, detail = str(error).partition(':') if isinstance(error, PackageError) else ('', '', '')
        audit['error'] = {'code': code if code in codes else 'package_verification_failed',
                          'exception_type': type(error).__name__}
        if code == 'package_reader_failed' and detail in {'rpm', 'rpm2cpio', 'dpkg-deb', 'unsquashfs'}:
            audit['error']['reader'] = detail
            if type(getattr(error, 'exit_code', None)) is int:
                audit['error']['exit_code'] = error.exit_code
        if code == 'packaged_native_bytes_changed' and re.fullmatch(r'[A-Za-z0-9_./-]{1,200}', detail):
            audit['error']['module'] = detail
        write_json(report_path, audit)
        print('Linux package audit failed: ' + json.dumps(audit['error'], ensure_ascii=True)
              + ' format=' + str(audit['format']) + ' stage=' + audit['stage'], file=sys.stderr)
        if isinstance(error, PackageError):
            raise
        raise PackageError('package_verification_failed') from error
    audit.update(passed=True, stage='complete')
    write_json(report_path, audit)
    return records


def _verify(context, dist, build, audit):
    arch = 'x64' if context['arch'] == 'amd64' else 'arm64'
    bundle = build/'linux'/arch/'release/bundle'
    expected = expected_modules(bundle)
    product = context['product_version'].split('+')[0].replace('-', '~', 1)
    number = str(context['build_number'])
    records = audit['packages']
    for kind in context['targets']:
        audit.update(format=kind, stage='package_selection')
        suffix = {'deb':'.deb', 'rpm':'.rpm', 'appimage':'.AppImage'}[kind]
        files = list(dist.glob('*' + suffix))
        if len(files) != 1 or files[0].is_symlink():
            raise PackageError('ambiguous_linux_package')
        package = files[0]
        audit['stage'] = 'metadata'
        if kind in ('deb', 'rpm'):
            with tempfile.TemporaryFile() as payload:
                if kind == 'rpm':
                    meta = run(['rpm','-qp','--qf','%{EPOCH}:%{VERSION}-%{RELEASE}',package], stdout=subprocess.PIPE).stdout.decode()
                    if not re.fullmatch(re.escape('1:' + product + '-' + number) + r'(?:\.[A-Za-z0-9._]+)?', meta):
                        raise PackageError('rpm_version_mismatch')
                    audit['stage'] = 'payload'
                    run(['rpm2cpio', package], stdout=payload)
                    payload.seek(0)
                    verify_members(cpio_members(payload), 'usr/share/'+context['package_app_name']+'/', expected,
                        ('usr/bin/'+context['package_app_name'], '/usr/share/'+context['package_app_name']+'/FlClash'))
                else:
                    meta = run(['dpkg-deb','-f',package,'Version'], stdout=subprocess.PIPE).stdout.decode().strip()
                    if meta != '1:' + product + '+' + number:
                        raise PackageError('deb_version_mismatch')
                    audit['stage'] = 'payload'
                    run(['dpkg-deb','--fsys-tarfile',package], stdout=payload)
                    payload.seek(0)
                    with tarfile.open(fileobj=payload, mode='r|') as archive:
                        def members():
                            for member in archive:
                                if member.isfile():
                                    if member.size > 512 * 1024 * 1024:
                                        raise PackageError('unsafe_tar_size')
                                    yield member.name, stat.S_IFREG | member.mode, archive.extractfile(member).read()
                                elif member.issym() or member.islnk():
                                    yield member.name, stat.S_IFLNK | member.mode, b''
                        verify_members(members(), 'usr/share/'+context['package_app_name']+'/', expected)
        else:
            audit['stage'] = 'appimage_readback'
            verify_appimage(package, expected, context['arch'])
        records.append({'format':kind, 'modules':len(expected)})
    return records


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--context', type=Path, default=Path('build/release-context.json'))
    p.add_argument('--dist', type=Path, default=Path('dist'))
    args = p.parse_args()
    from release_pipeline import read_context
    context = read_context(args.context)
    if context['platform'] != 'linux':
        raise PackageError('linux_context_required')
    print(json.dumps({'passed': True, 'packages':verify(context,args.dist)}))


if __name__ == '__main__':
    main()
