#!/usr/bin/env python3
"""Portable ELF32/ELF64 and real ZIP/CLI tests; no native compilation or upload."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sentry_android_inventory import inventory
import prepare_sentry_native_symbols as prep


def elf(arm32=False, build_id=True):
    size, width = (52, 40) if arm32 else (64, 64)
    names = b'\0.shstrtab\0.note.gnu.build-id\0.text\0'
    note = struct.pack('<III', 4, 20, 3) + b'GNU\0' + b'B' * 20
    parts = [(b'.shstrtab', 3, names), (b'.text', 1, b'code')]
    if build_id:
        parts.append((b'.note.gnu.build-id', 7, note))
    payload, headers = bytearray(), [bytes(width)]
    for name, kind, data in parts:
        headers.append(struct.pack('<' + ('IIIIIIIIII' if arm32 else 'IIQQQQIIQQ'),
            names.index(name+b'\0'), kind, 0, 0, size+len(payload), len(data), 0, 0, 1, 0))
        payload.extend(data)
    header = struct.pack('<16s' + ('HHIIIIIHHHHHH' if arm32 else 'HHIQQQIHHHHHH'),
        b'\x7fELF'+bytes([1 if arm32 else 2, 1, 1])+bytes(9), 3, 40 if arm32 else 183,
        1, 0, 0, size+len(payload), 0, size, 0, 0, width, len(headers), 1)
    return header + payload + b''.join(headers)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def package(self, abi, prefix='omo', bad=None, omit=None):
        path = self.root / f'{prefix}-0.0.1-android-{abi}.apk'
        with zipfile.ZipFile(path, 'w') as archive:
            for name in ['libapp.so', 'libflutter.so', 'libclash.so', 'librust_api.so']:
                if name == omit: continue
                data = elf(abi == 'armeabi-v7a')
                if bad and name == bad[0]: data = bad[1]
                archive.writestr(f'lib/{abi}/{name}', data)
        return path

    def test_both_brands_real_elf32_64_and_both_package_orders(self):
        for prefix in ['omo', 'ds']:
            packages = [self.package(abi, prefix) for abi in ['armeabi-v7a', 'arm64-v8a']]
            for order in [packages, packages[::-1]]:
                result = inventory(order, ['armeabi-v7a', 'arm64-v8a'])
                self.assertEqual(result['errors'], [])
                self.assertEqual(len(result['modules']), 8)
                self.assertEqual({r['actual_architecture'] for r in result['modules']}, {'arm', 'aarch64'})

    def test_wrong_architecture_and_missing_id_are_distinct_and_both_reported(self):
        a = self.package('armeabi-v7a', bad=('libclash.so', elf(False)))
        b = self.package('arm64-v8a', bad=('librust_api.so', elf(False, False)))
        result = inventory([a,b], ['armeabi-v7a','arm64-v8a'])
        self.assertEqual([e['code'] for e in result['errors']], ['runtime_architecture_mismatch','runtime_build_id_missing'])
        self.assertEqual([e['module'] for e in result['errors']], ['libclash.so','librust_api.so'])
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_missing_abi_and_owned_library_fail(self):
        p = self.package('arm64-v8a', omit='librust_api.so')
        codes = {e['code'] for e in inventory([p], ['armeabi-v7a','arm64-v8a'])['errors']}
        self.assertEqual(codes, {'required_apk_native_module_missing','runtime_abi_set_mismatch'})

    def test_optional_id_absence_is_not_relaxed_architecture_check(self):
        p = self.package('arm64-v8a', bad=('libflutter.so',elf(False,False)))
        self.assertEqual(inventory([p])['errors'], [])
        p = self.package('arm64-v8a', bad=('libflutter.so',elf(True)))
        self.assertEqual(inventory([p])['errors'][0]['code'],'runtime_architecture_mismatch')

    def test_corrupt_elf_and_empty_package_fail(self):
        p = self.package('arm64-v8a',bad=('libclash.so',b'bad'))
        self.assertEqual(inventory([p])['errors'][0]['code'],'invalid_native_elf')
        self.assertEqual(inventory([])['errors'][0]['code'],'flutter_runtime_abi_missing')

    def test_real_cli_reports_before_objcopy_and_removes_stale_manifest(self):
        build = self.root / 'build'
        manifest = build / 'sentry-native/android/manifest.json'
        manifest.parent.mkdir(parents=True); manifest.write_text('{}')
        p = self.package('armeabi-v7a',bad=('libclash.so',elf(False)))
        run = subprocess.run([sys.executable, prep.__file__, '--platform','android','--build-root',str(build),
            '--objcopy','must-not-execute','--package',str(p),'--expected-abi','armeabi-v7a'],capture_output=True,text=True)
        self.assertEqual(run.returncode,1,run.stderr)
        report = json.loads((build / 'sentry-native-preparation.json').read_text())
        self.assertEqual(report['failure_code'],'runtime_architecture_mismatch')
        self.assertEqual(report['errors'][0]['module'],'libclash.so')
        self.assertFalse(manifest.exists())

    def test_prep_failure_after_valid_inventory_retains_module_context(self):
        p = self.package('arm64-v8a')
        build = self.root / 'build'
        with mock.patch.object(prep.Preparer,'android',side_effect=prep.PreparationError('required_native_dwarf_unavailable')):
            self.assertEqual(prep.main(['--platform','android','--build-root',str(build),'--objcopy','unused','--package',str(p)]),1)
        report = json.loads((build/'sentry-native-preparation.json').read_text())
        self.assertEqual(report['status'],'failed')
        self.assertEqual(len(report['modules']),4)
        self.assertEqual(report['errors'][0]['code'],'required_native_dwarf_unavailable')


if __name__ == '__main__': unittest.main()
