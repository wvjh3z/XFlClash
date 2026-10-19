"""Two brands, all runtime asset layouts; no native compilation or real config."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import warnings
import zipfile

spec=importlib.util.spec_from_file_location('fallback_checker',Path(__file__).resolve().parents[1]/'check_fallback_assets.py')
checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)


class FallbackAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)

    def source(self,brand):
        source=self.root/f'flavors/{brand}/assets/fallback.bin'
        source.parent.mkdir(parents=True,exist_ok=True);source.write_bytes(('ciphertext-'+brand).encode())
        return source

    def test_both_brands_all_desktop_layouts_verify_selected_bytes(self):
        for brand in ('brand_a','brand_b'):
            for platform,path in [('windows','windows/x64/runner/Release/data/flutter_assets'),
                                  ('linux','linux/x64/release/bundle/data/flutter_assets'),
                                  ('linux','linux/arm64/release/bundle/data/flutter_assets'),
                                  ('macos','macos/Build/Products/Release/袋鼠.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets')]:
                with self.subTest(brand=brand,platform=platform,path=path):
                    source=self.source(brand);assets=self.root/'build'/path
                    dest=assets/source.relative_to(self.root);dest.parent.mkdir(parents=True);shutil.copy2(source,dest)
                    self.assertTrue(checker.verify(self.root,brand,platform)['passed'])
                    dest.write_bytes(b'wrong')
                    with self.assertRaises(ValueError):checker.verify(self.root,brand,platform)
                    shutil.copy2(source,dest)
                    other=assets/'flavors'/('brand_b' if brand=='brand_a' else 'brand_a')/'assets/fallback.bin'
                    other.parent.mkdir(parents=True);other.write_bytes(b'other')
                    with self.assertRaises(ValueError):checker.verify(self.root,brand,platform)
                    other.unlink();dest.unlink()
                    with self.assertRaises(ValueError):checker.verify(self.root,brand,platform)
                    shutil.rmtree(self.root/'build')

    def test_both_apk_abis_reject_missing_mixed_duplicate_and_changed_fallback(self):
        for brand in ('brand_a','brand_b'):
            source=self.source(brand);wanted='assets/flutter_assets/'+source.relative_to(self.root).as_posix()
            for variant in ('good','missing','mixed','duplicate','changed'):
                packages=[]
                for abi in ('arm64-v8a','armeabi-v7a'):
                    package=self.root/(abi+'.apk');packages.append(package)
                    with warnings.catch_warnings():
                        warnings.simplefilter('ignore',UserWarning)
                        with zipfile.ZipFile(package,'w') as z:
                            if variant!='missing':z.writestr(wanted,b'wrong' if variant=='changed' else source.read_bytes())
                            if variant=='duplicate':z.writestr(wanted,source.read_bytes())
                            if variant=='mixed':z.writestr('assets/flutter_assets/flavors/other/assets/fallback.bin',b'other')
                with self.subTest(brand=brand,variant=variant):
                    if variant=='good':self.assertEqual(len(checker.verify(self.root,brand,'android',packages=packages)['checked']),2)
                    else:
                        with self.assertRaises(ValueError):checker.verify(self.root,brand,'android',packages=packages)

    def test_no_bundle_or_apk_and_empty_source_fail(self):
        self.source('brand_a')
        for platform in ('android','linux','windows','macos'):
            with self.assertRaises(ValueError):checker.verify(self.root,'brand_a',platform)
        self.source('brand_a').write_bytes(b'')
        with self.assertRaises(ValueError):checker.verify(self.root,'brand_a','linux')

    def test_local_fingerprint_ignores_only_owned_brand_selection(self):
        a=b'name: test\n    # xboard-fallback-assets:begin\n    - flavors/brand_a/assets/\n    # xboard-fallback-assets:end\nversion: 1\n'
        b=a.replace(b'brand_a/assets/',b'brand_b/assets/fallback.bin')
        self.assertEqual(checker.canonical_pubspec(a),checker.canonical_pubspec(b))
        self.assertNotEqual(checker.canonical_pubspec(a),checker.canonical_pubspec(b.replace(b'version: 1',b'version: 2')))
        for bad in (a+a,a.replace(b'brand_a',b'brand_c'),a.replace(b'- flavors/',b'- private/'),b'no markers'):
            with self.assertRaises(ValueError):checker.canonical_pubspec(bad)

    def test_restore_only_injected_block_preserves_other_edits_and_newlines(self):
        for brand in ('brand_a','brand_b'):
            for newline in (b'\n',b'\r\n'):
                original=newline.join([b'version: 1',b'    # xboard-fallback-assets:begin',
                    b'    # original comment',b'    - flavors/brand_a/assets/',
                    b'    # xboard-fallback-assets:end',b'description: before',b''])
                current=original.replace(b'    # original comment'+newline,b'').replace(
                    b'    - flavors/brand_a/assets/',f'    - flavors/{brand}/assets/fallback.bin'.encode())
                current=current.replace(b'version: 1',b'version: 2').replace(b'description: before',b'description: user edit')
                restored=checker.restore_pubspec_asset_block(original,current,brand)
                self.assertEqual(restored,original.replace(b'version: 1',b'version: 2').replace(b'description: before',b'description: user edit'))
                self.assertEqual(checker.restore_pubspec_asset_block(original,restored,brand),restored)

    def test_restore_conflicts_never_supply_a_whole_file_fallback(self):
        original=b'version: 1\n    # xboard-fallback-assets:begin\n    - flavors/brand_a/assets/\n    # xboard-fallback-assets:end\n'
        for current in (b'user replacement',original.replace(b'brand_a',b'brand_b'),original+original,
                        original.replace(b'assets/',b'assets/fallback.bin # user comment')):
            with self.assertRaises(ValueError):checker.restore_pubspec_asset_block(original,current,'brand_a')


if __name__=='__main__':unittest.main()
