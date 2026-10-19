"""Real pinned APK maker -> production normalize -> final manifest verification.

Run after distributor activation, before client compilation. Only the APK input
bytes are synthetic. No Flutter build, signing, secrets, publishing or network.
--packages can select an already resolved distributor graph for local checks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
try:
    from .distributor_fixture import PACKAGES, resolved_packages
except ImportError:
    from distributor_fixture import PACKAGES, resolved_packages

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
import release_pipeline as pipeline


class AndroidArtifactPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        dart = shutil.which('dart')
        if not dart or not PACKAGES.is_file():
            raise RuntimeError('Dart and resolved distributor packages required; activate before this check')
        native = Path(dart).resolve().parent / 'cache/dart-sdk/bin/dart'
        if native.is_file():
            dart = str(native)
        cls.fixture = tempfile.TemporaryDirectory(prefix='real-apk-maker-')
        cls.addClassCleanup(cls.fixture.cleanup)
        cls.base = Path(cls.fixture.name)
        packages = resolved_packages(PACKAGES)
        graph = cls.base / 'package_config.json'
        graph.write_text(json.dumps({'configVersion': 2, 'packages': list(packages.values())}), encoding='utf-8')
        env = {k:v for k,v in os.environ.items() if not any(x in k.upper() for x in ('TOKEN', 'PASSWORD', 'SECRET', 'DSN'))}
        result = subprocess.run([dart, '--packages='+str(graph),
                                 str(ROOT / 'tool/test/android_apk_maker_fixture.dart'), str(cls.base)],
                                cwd=cls.base, env=env, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError('Real APK maker fixture failed:\n'+result.stdout+result.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='apk-normalize-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def inputs(self, brand):
        root = self.root / brand
        root.mkdir()
        dist = root / 'dist'
        shutil.copytree(self.base / brand / 'dist', dist)
        context = {'schema_version':1, 'flavor':brand, 'platform':'android', 'arch':'',
                   'product_version':'0.0.1', 'base_version':'0.8.93', 'build_number':30,
                   'source_revision':'a'*40, 'build_tag':'202610182200', 'targets':['apk'],
                   'package_prefix':'omo' if brand == 'brand_a' else 'ds',
                   'package_app_name':'OmoFly' if brand == 'brand_a' else 'ds'}
        prefix = context['package_prefix']
        # User-facing contract is independent of production expected_artifacts().
        expected = {f'{prefix}-0.0.1-android-{abi}.apk':
                    f'harmless fixture {brand} {abi}'.encode()
                    for abi in ('armeabi-v7a', 'arm64-v8a')}
        return context, dist, root / 'manifest.json', expected

    def check_rejected_without_changes(self, context, dist, report):
        before = {p.name:p.read_bytes() for p in dist.iterdir()}
        report.write_text('{"passed":true}', encoding='utf-8')
        with mock.patch.object(Path, 'rename') as rename:
            with self.assertRaises(pipeline.PipelineError):
                pipeline.normalize(context, dist, report)
            rename.assert_not_called()
        self.assertEqual(before, {p.name:p.read_bytes() for p in dist.iterdir()})
        self.assertFalse(json.loads(report.read_text(encoding='utf-8'))['passed'])

    def test_both_real_makers_normalize_and_verify_exact_final_names_and_hashes(self):
        for brand in ('brand_a', 'brand_b'):
            with self.subTest(brand=brand):
                c,dist,report,expected = self.inputs(brand)
                # Old suffix matching must fail on the real maker's files.
                self.assertFalse(any(p.name.endswith('armeabi-v7a.apk') for p in dist.iterdir()))
                manifest = pipeline.normalize(c,dist,report)
                self.assertEqual(expected,{p.name:p.read_bytes() for p in dist.iterdir()})
                for row in manifest['artifacts']:
                    data = expected[row['file']]
                    self.assertEqual(row['size'], len(data))
                    self.assertEqual(row['sha256'], hashlib.sha256(data).hexdigest())
                self.assertEqual({Path(p).name for p in pipeline.verified_files(c,dist,report)}, set(expected))
                self.assertEqual(pipeline.normalize(c,dist,report), manifest)
                pipeline.verified_files(c,dist,report)

    def test_partial_previous_rename_with_one_file_per_abi_is_idempotent(self):
        for brand in ('brand_a','brand_b'):
            c,dist,report,expected = self.inputs(brand)
            raw = next(dist.glob('*-arm64-v8a-*.apk'))
            raw.rename(dist / next(n for n in expected if n.endswith('arm64-v8a.apk')))
            pipeline.normalize(c,dist,report)
            self.assertEqual(set(expected), {Path(p).name for p in pipeline.verified_files(c,dist,report)})

    def test_missing_empty_cross_brand_old_version_wrong_name_and_unknown_abi_rejected(self):
        for brand in ('brand_a','brand_b'):
            for mutation in ('missing','empty','brand','version','name','abi'):
                with self.subTest(brand=brand,mutation=mutation):
                    c,dist,report,_ = self.inputs(brand)
                    raw = next(dist.glob('*-armeabi-v7a-*.apk'))
                    if mutation == 'missing': raw.unlink()
                    elif mutation == 'empty': raw.write_bytes(b'')
                    else:
                        replacements = {'brand':(brand,'brand_b' if brand=='brand_a' else 'brand_a'),
                                        'version':('0.8.93','0.8.92'), 'name':(c['package_app_name'],'unknown'),
                                        'abi':('armeabi-v7a','x86_64')}
                        old,new = replacements[mutation]
                        raw.rename(raw.with_name(raw.name.replace(old,new)))
                    self.check_rejected_without_changes(c,dist,report)
                    shutil.rmtree(dist.parent)

    def test_raw_plus_final_duplicate_and_extra_packages_rejected(self):
        for brand in ('brand_a','brand_b'):
            for extra in ('duplicate','unknown.apk','wrong-brand-arm64-v8a.apk','extra.zip'):
                with self.subTest(brand=brand,extra=extra):
                    c,dist,report,expected = self.inputs(brand)
                    name = next(n for n in expected if n.endswith('arm64-v8a.apk')) if extra=='duplicate' else extra
                    (dist/name).write_bytes(b'do not overwrite')
                    self.check_rejected_without_changes(c,dist,report)
                    shutil.rmtree(dist.parent)

    @unittest.skipIf(os.name == 'nt', 'POSIX symlink control')
    def test_symlink_input_rejected_and_target_preserved(self):
        for brand in ('brand_a','brand_b'):
            c,dist,report,_ = self.inputs(brand)
            raw = next(dist.glob('*-armeabi-v7a-*.apk'))
            target = dist.parent/'outside'; raw.rename(target); raw.symlink_to(target)
            data = target.read_bytes()
            self.check_rejected_without_changes(c,dist,report)
            self.assertTrue(raw.is_symlink()); self.assertEqual(target.read_bytes(),data)

    def test_final_manifest_rejects_tampering_and_context_mismatch(self):
        for brand in ('brand_a','brand_b'):
            c,dist,report,expected = self.inputs(brand)
            pipeline.normalize(c,dist,report)
            original = report.read_bytes()
            for change in ({'flavor':'wrong'}, {'build_number':31}, {'source_revision':'b'*40}):
                with self.assertRaises(pipeline.PipelineError):pipeline.verified_files({**c,**change},dist,report)
            for field,value in (('sha256','0'*64),('size',1),('file','wrong.apk')):
                data=json.loads(original);data['artifacts'][0][field]=value
                report.write_text(json.dumps(data),encoding='utf-8')
                with self.assertRaises(pipeline.PipelineError):pipeline.verified_files(c,dist,report)
            report.write_bytes(original)
            file=dist/next(iter(expected));data=file.read_bytes()
            file.write_bytes(b'X'+data[1:])  # same size: digest must detect the change
            with self.assertRaises(pipeline.PipelineError):pipeline.verified_files(c,dist,report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--packages', type=Path, default=PACKAGES)
    options, remaining = parser.parse_known_args()
    PACKAGES = options.packages.resolve()
    unittest.main(argv=[sys.argv[0], *remaining])
