"""Safety checks for the local native diagnostic; never build a client."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_smoke', Path(__file__).parents[1] / 'run_native_upgrade_smoke.py')
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class NativeSmokeTest(unittest.TestCase):
    def test_real_documents_lookup_isolated_with_unicode_path(self):
        if not shutil.which('xdg-user-dir'):
            self.skipTest('xdg-user-dir is required on the Linux smoke host')
        with tempfile.TemporaryDirectory(prefix="smoke-中文-") as folder:
            batch = Path(folder)
            env = dict(os.environ)
            smoke.isolate_directories(batch, env)
            path = subprocess.check_output(['xdg-user-dir', 'DOCUMENTS'], env=env, text=True).strip()
            self.assertEqual(Path(path), batch / 'documents')
            self.assertTrue(Path(path).is_dir())
            # Without the file, XDG_DATA_HOME alone does not isolate Documents.
            (batch / 'config/user-dirs.dirs').unlink()
            fallback = subprocess.check_output(['xdg-user-dir', 'DOCUMENTS'], env=env, text=True).strip()
            self.assertNotEqual(Path(fallback), batch / 'documents')

    def fixture(self, root, flavor):
        asset = root / 'flavors' / flavor / 'assets'
        (asset / 'icons').mkdir(parents=True)
        (asset / 'icons' / (flavor + '.png')).write_bytes(flavor.encode())
        (root / 'assets/images').mkdir(parents=True, exist_ok=True)
        (root / 'assets/images/icon.png').write_bytes(b'original-icon')
        (root / 'pubspec.yaml').write_bytes(b'flutter:\r\n  assets:\r\n    # xboard-fallback-assets:begin\r\n    - flavors/brand_a/assets/\r\n    # xboard-fallback-assets:end\r\n')
        return asset / 'fallback.bin'

    def test_both_brand_assets_restore_byte_for_byte_on_error(self):
        for flavor in ('brand_a', 'brand_b'):
            with self.subTest(flavor=flavor), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                fallback = self.fixture(root, flavor)
                original = (root / 'pubspec.yaml').read_bytes()
                with self.assertRaisesRegex(RuntimeError, 'controlled failure'):
                    with smoke.fixture_assets(root, flavor, 31991):
                        self.assertTrue(fallback.exists())
                        self.assertEqual((root / 'assets/images/icon.png').read_bytes(), flavor.encode())
                        raise RuntimeError('controlled failure')
                self.assertFalse(fallback.exists())
                self.assertEqual((root / 'pubspec.yaml').read_bytes(), original)
                self.assertEqual((root / 'assets/images/icon.png').read_bytes(), b'original-icon')

    def test_production_fallback_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            fallback = self.fixture(root, 'brand_a')
            fallback.write_bytes(b'do-not-touch')
            with self.assertRaisesRegex(RuntimeError, 'production fallback'):
                with smoke.fixture_assets(root, 'brand_a', 31991):
                    self.fail('must reject before the context body')
            self.assertEqual(fallback.read_bytes(), b'do-not-touch')

    def test_missing_asset_marker_is_rejected_before_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            fallback = self.fixture(root, 'brand_a')
            (root / 'pubspec.yaml').write_bytes(b'no-marker\r\n')
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                with smoke.fixture_assets(root, 'brand_a', 31991):
                    self.fail('must not enter')
            self.assertFalse(fallback.exists())
            self.assertEqual((root / 'pubspec.yaml').read_bytes(), b'no-marker\r\n')

    def test_filtered_hook_environment_keeps_toolchain_and_arguments(self):
        with tempfile.TemporaryDirectory(prefix='smoke 中文 ') as folder:
            root = Path(folder)
            tc = root / 'toolchains'
            for relative in ['go-1.27.1/bin/go', *['rust/cargo/bin/' + x for x in ('rustup', 'cargo', 'rustc')]]:
                executable = tc / relative
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text('#!/usr/bin/python3\nimport json,os,sys\nprint(json.dumps({"args":sys.argv[1:],"cache":os.environ.get("GOCACHE"),"rust":os.environ.get("RUSTUP_HOME")}))\n')
                executable.chmod(0o700)
            with patch.dict(os.environ, {'SENTRY_AUTH_TOKEN': 'test-only-token'}):
                env = smoke.compiler_environment(root, tc)
            self.assertNotIn('SENTRY_AUTH_TOKEN', env)
            import json
            for command in ('go', 'cargo'):
                out = subprocess.check_output([command, '中文 space', '$literal'], env={'PATH': env['PATH']}, text=True)
                result = json.loads(out)
                self.assertEqual(result['args'], ['中文 space', '$literal'])
                self.assertEqual(result['cache'], str(tc / 'cache/go-build'))
                self.assertEqual(result['rust'], str(tc / 'rust/rustup'))


if __name__ == '__main__':
    unittest.main()
