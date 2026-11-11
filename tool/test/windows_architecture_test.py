"""Target identity negative controls; no Windows program is executed."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from windows_architecture import verify_bundle, verify_dart
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
    def test_mislabeled_x64_dart_cannot_build_arm64(self):
        for arch in ('x64', 'arm64'):
            verify_dart(arch, f'Dart SDK version: 3.13.5 (stable) on "windows_{arch}"')
        with self.assertRaises(ValueError):
            verify_dart('arm64', 'Dart SDK version: 3.13.5 on "windows_x64"')

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


if __name__ == '__main__':
    unittest.main()
