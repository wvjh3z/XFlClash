"""Target identity negative controls; no Windows program is executed."""
from pathlib import Path
import os
import hashlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from windows_architecture import dart_target, verify_bundle, verify_dart
import windows_architecture
from release_pipeline import package_environment
from sentry_symbols_test import elf_fixture


def pe(path, machine):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = bytearray(128)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 64)
    data[64:68] = b'PE\0\0'
    struct.pack_into('<H', data, 68, machine)
    path.write_bytes(data)


class WindowsArchitectureTests(unittest.TestCase):
    def test_local_entry_accepts_arm64_and_resolves_emulated_bash_before_abi_gate(self):
        source = Path(__file__).resolve().parents[2] / 'scripts/package_desktop_local.sh'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root/'scripts/package_desktop_local.sh'
            script.parent.mkdir()
            script.write_bytes(source.read_bytes())
            flavor = root/'flavors/brand_a/flavor.yaml'
            flavor.parent.mkdir(parents=True)
            flavor.write_text('fixture', encoding='utf-8')
            tools = root/'bin'
            tools.mkdir()
            commands = {
                'uname': 'if [ "$1" = -s ]; then echo MINGW64_NT; else echo x86_64; fi',
                'flutter': 'echo BOOTSTRAP',
                'dart': 'exit 0',
                'python3': 'if [ "$2" = --print-target ]; then echo arm64; exit 0; fi; printf "CHECK %s\\n" "$*"; exit 47',
            }
            for name, body in commands.items():
                path = tools/name
                path.write_text('#!/usr/bin/env bash\n'+body+'\n', encoding='utf-8')
                path.chmod(0o755)
            env = {**os.environ, 'PATH': str(tools)+os.pathsep+os.environ['PATH'],
                   'PROCESSOR_ARCHITEW6432': 'AMD64', 'PROCESSOR_ARCHITECTURE': 'AMD64'}
            for target in ('windows-arm64', 'auto'):
                result = subprocess.run([shutil.which('bash'), script.as_posix(), 'brand_a', target,
                                         '--build-number=51'], env=env, capture_output=True,
                                        text=True, encoding='utf-8', errors='replace', timeout=15)
                self.assertEqual(result.returncode, 47, result.stdout+result.stderr)
                self.assertIn('CHECK tool/windows_architecture.py --architecture arm64', result.stdout)
                self.assertLess(result.stdout.index('BOOTSTRAP'), result.stdout.index('CHECK'))

    def test_mislabeled_x64_dart_cannot_build_arm64(self):
        for arch in ('x64', 'arm64'):
            verify_dart(arch, f'Dart SDK version: 3.13.5 (stable) on "windows_{arch}"')
            self.assertEqual(dart_target(f'Dart SDK version: 3.13.5 (stable) on "windows_{arch}"'),
                             'amd64' if arch == 'x64' else 'arm64')
        with self.assertRaises(ValueError):
            verify_dart('arm64', 'Dart SDK version: 3.13.5 on "windows_x64"')
        for invalid in ('on "linux_arm64"', 'on "windows_x64" on "windows_arm64"', ''):
            with self.assertRaises(ValueError):
                dart_target(invalid)

    def test_both_brand_bundles_reject_one_mixed_architecture_dependency(self):
        for brand in ('OmoFly', 'Daishu'):
            for arch, machine, other in [('amd64', 0x8664, 0xaa64), ('arm64', 0xaa64, 0x8664)]:
                with self.subTest(brand=brand, arch=arch), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    for name in (brand+'.exe', brand+'Core.exe', brand+'HelperService.exe',
                                 'flutter_windows.dll', 'rust_api.dll', 'WebView2Loader.dll'):
                        pe(root/name, machine)
                    (root/'data').mkdir()
                    aot_arch = 'x86_64' if arch == 'amd64' else 'aarch64'
                    (root/'data/app.so').write_bytes(elf_fixture(architecture=aot_arch, executable=True))
                    pe(root/'EnableLoopback.exe', 0x14c)
                    self.assertTrue(verify_bundle(root, arch)['passed'])
                    pe(root/'WebView2Loader.dll', other)
                    with self.assertRaisesRegex(ValueError, 'WebView2Loader'):
                        verify_bundle(root, arch)
                    pe(root/'WebView2Loader.dll', machine)
                    (root/'data/app.so').write_bytes(elf_fixture(
                        architecture='aarch64' if arch == 'amd64' else 'x86_64', executable=True))
                    with self.assertRaisesRegex(ValueError, 'AOT'):
                        verify_bundle(root, arch)
                    (root/'data/app.so').unlink()
                    with self.assertRaisesRegex(ValueError, 'Incomplete'):
                        verify_bundle(root, arch)

    def test_arm64_selects_supported_sentry_override_without_mutating_parent(self):
        inherited = {'SENTRY_NATIVE_BACKEND': 'crashpad', 'KEEP': 'value'}
        result = package_environment({'platform': 'windows', 'arch': 'arm64'}, inherited)
        self.assertEqual(result, {'SENTRY_NATIVE_BACKEND': 'breakpad', 'KEEP': 'value'})
        self.assertEqual(package_environment({'platform': 'windows', 'arch': 'amd64'}, inherited), inherited)
        self.assertEqual(inherited['SENTRY_NATIVE_BACKEND'], 'crashpad')

    def test_arm64x_crt_exception_requires_exact_name_and_bytes(self):
        # Synthetic policy boundary; the real pinned signed DLL is independently
        # checked against the upstream release, not replaced by this fixture.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('OmoFly.exe', 'flutter_windows.dll'):
                pe(root/name, 0xaa64)
            (root/'data').mkdir()
            (root/'data/app.so').write_bytes(elf_fixture(architecture='aarch64', executable=True))
            runtime = root/'vcruntime140_1.dll'
            pe(runtime, 0x8664)
            with self.assertRaisesRegex(ValueError, 'vcruntime140_1.dll'):
                verify_bundle(root, 'arm64')
            original = runtime.read_bytes()
            digest = hashlib.sha256(original).hexdigest()
            with mock.patch.dict(windows_architecture.PINNED_ARM64X_CRT,
                                 {'vcruntime140_1.dll': digest}, clear=True):
                report = verify_bundle(root, 'arm64')
                row = next(row for row in report['files'] if row['file'] == runtime.name)
                self.assertEqual(row['format'], 'pinned-microsoft-arm64x-crt')
                self.assertEqual(row['sha256'], digest)
                runtime.write_bytes(original+b'changed')
                with self.assertRaisesRegex(ValueError, 'sha256='):
                    verify_bundle(root, 'arm64')
                runtime.write_bytes(original)
                runtime.rename(root/'unexpected_plugin.dll')
                with self.assertRaisesRegex(ValueError, 'unexpected_plugin.dll'):
                    verify_bundle(root, 'arm64')


if __name__ == '__main__':
    unittest.main()
