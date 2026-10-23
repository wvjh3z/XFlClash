"""Container/readback regressions; no client compile, image execution or upload."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import verify_linux_packages as checker
import release_pipeline
try:
    from .release_pipeline_test import context
except ImportError:
    from release_pipeline_test import context
ROOT=Path(__file__).resolve().parents[2]


def runtime_header(machine=62):
    # Synthetic non-executable runtime, accurately preserving type-2 layout.
    data=bytearray(128);data[:7]=b'\x7fELF\x02\x01\x01';data[8:11]=b'AI\x02'
    struct.pack_into('<HHI',data,16,2,machine,1)
    struct.pack_into('<Q',data,40,64)
    struct.pack_into('<H',data,52,64)
    struct.pack_into('<HH',data,58,64,1)
    return bytes(data)


class ContainerHeaderTests(unittest.TestCase):
    def test_both_architectures_and_corrupt_or_plain_squashfs(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'fixture.AppImage'
            for arch,machine in [('amd64',62),('arm64',183)]:
                valid=runtime_header(machine)+b'hsqs'+bytes(92)
                path.write_bytes(valid)
                self.assertEqual(checker.appimage_payload_offset(path,arch),128)
                with self.assertRaisesRegex(checker.PackageError,'architecture_mismatch'):
                    checker.appimage_payload_offset(path,'arm64' if arch=='amd64' else 'amd64')
                mutations=[b'hsqs'+bytes(160), valid[:63],valid[:128]+b'bad!'+bytes(92)]
                for offset,fmt,value in [(40,'<Q',2**63),(58,'<H',0),(60,'<H',0),(52,'<H',32)]:
                    bad=bytearray(valid);struct.pack_into(fmt,bad,offset,value);mutations.append(bytes(bad))
                for bad in mutations:
                    path.write_bytes(bad)
                    with self.assertRaises(checker.PackageError):checker.appimage_payload_offset(path,arch)

    def test_failure_report_is_fresh_bounded_and_does_not_copy_exceptions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);build=root/'build';build.mkdir();report=build/'linux-package-audit.json'
            report.write_text('{"passed":true}',encoding='utf-8')
            for error in (OSError('PRIVATE_MARKER /private/path'), checker.PackageError('PRIVATE_MARKER'),
                          checker.PackageError('package_reader_failed:unsquashfs')):
                with mock.patch.object(checker,'_verify',side_effect=error),self.assertRaises(checker.PackageError):
                    checker.verify(context('linux'),root/'dist',build)
                data=json.loads(report.read_text(encoding='utf-8'))
                self.assertFalse(data['passed']);self.assertEqual(data['stage'],'bundle')
                self.assertNotIn('PRIVATE_MARKER',report.read_text(encoding='utf-8'))
                self.assertNotIn('/private/path',report.read_text(encoding='utf-8'))

    def test_workflow_preserves_linux_failure_report(self):
        workflow=(ROOT/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        evidence=workflow.split('- name: Preserve safe Sentry symbol evidence',1)[1].split('\n      - name:',1)[0]
        self.assertIn('if: always()',evidence)
        self.assertIn('build/linux-package-audit.json',evidence)


@unittest.skipUnless(sys.platform=='linux','Real SquashFS reader uses Linux tools')
class RealSquashFSReadbackTests(unittest.TestCase):
    def setUp(self):
        for name in ('mksquashfs','unsquashfs'):
            if not shutil.which(name):raise RuntimeError('Required reader fixture tool missing: '+name)
        self.temp=tempfile.TemporaryDirectory(prefix='appimage-readback-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)

    def fixture(self,brand,arch):
        root=self.root/(brand+arch);bundle=root/'build/linux'/('x64' if arch=='amd64' else arch)/'release/bundle'
        bundle.mkdir(parents=True);(root/'dist').mkdir()
        for name in ('FlClash','FlClashCore','FlClashHelperService'):
            (bundle/name).write_bytes(b'\x7fELF'+(brand+arch+name).encode());(bundle/name).chmod(0o755)
        payload=root/'payload.squashfs'
        subprocess.run(['mksquashfs',str(bundle),str(payload),'-noappend','-quiet','-processors','1'],
                       check=True,capture_output=True,timeout=30)
        package=root/'dist/fixture.AppImage'
        package.write_bytes(runtime_header(62 if arch=='amd64' else 183)+payload.read_bytes())
        c=context('linux',arch,flavor=brand,package_prefix='omo' if brand=='brand_a' else 'ds',targets=['appimage'])
        return root,bundle,payload,package,c

    def test_real_reader_both_brands_architectures_and_old_offset_negative(self):
        for brand in ('brand_a','brand_b'):
            for arch in ('amd64','arm64'):
                with self.subTest(brand=brand,arch=arch):
                    root,bundle,payload,package,c=self.fixture(brand,arch)
                    old=subprocess.run(['unsquashfs','-cat',str(package),'FlClash'],capture_output=True,timeout=30)
                    self.assertNotEqual(old.returncode,0)
                    records=checker.verify(c,root/'dist',root/'build')
                    self.assertEqual(records,[{'format':'appimage','modules':3}])
                    self.assertTrue(json.loads((root/'build/linux-package-audit.json').read_text())['passed'])
                    (bundle/'FlClashCore').write_bytes(b'\x7fELFchanged')
                    with self.assertRaisesRegex(checker.PackageError,'packaged_native_bytes_changed:FlClashCore'):
                        checker.verify(c,root/'dist',root/'build')
                    error=json.loads((root/'build/linux-package-audit.json').read_text())
                    self.assertFalse(error['passed']);self.assertEqual(error['format'],'appimage')
                    self.assertEqual(error['error']['module'],'FlClashCore')
                    # The old full-pipeline fixture was only a renamed raw filesystem.
                    package.write_bytes(payload.read_bytes())
                    with self.assertRaisesRegex(checker.PackageError,'invalid_appimage_container'):
                        checker.verify(c,root/'dist',root/'build')

    def test_formal_normalize_verify_and_upload_stop_with_diagnostic(self):
        root,bundle,payload,package,c=self.fixture('brand_a','amd64')
        c['targets']=['deb','appimage']
        debroot=root/'deb-root';control=debroot/'DEBIAN';control.mkdir(parents=True)
        control.chmod(0o755)
        (control/'control').write_text('Package: fixture\nVersion: 1:0.0.1+30\nArchitecture: amd64\n'
            'Maintainer: Fixture <fixture@example.invalid>\nDescription: public readback fixture\n',encoding='utf-8')
        shutil.copytree(bundle,debroot/'usr/share/OmoFly')
        subprocess.run(['dpkg-deb','--build',str(debroot),str(root/'dist/fixture.deb')],
                       check=True,capture_output=True,timeout=30)
        (root/'build/release-context.json').write_text(json.dumps(c),encoding='utf-8')
        command=[sys.executable,str(ROOT/'tool/release_pipeline.py')]
        good=subprocess.run(command+['normalize'],cwd=root,capture_output=True,text=True,timeout=30)
        self.assertEqual(good.returncode,0,good.stdout+good.stderr)
        manifest=root/'build/release-artifacts.json'
        valid_manifest=manifest.read_bytes()
        (bundle/'FlClashCore').write_bytes(b'\x7fELFmodified')
        for action in ('normalize','verify','upload'):
            manifest.write_bytes(valid_manifest)
            result=subprocess.run(command+[action],cwd=root,capture_output=True,text=True,timeout=30)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('packaged_native_bytes_changed',result.stderr)
            self.assertFalse(json.loads(manifest.read_text())['passed'])
            report=json.loads((root/'build/linux-package-audit.json').read_text())
            self.assertEqual(report['error']['module'],'FlClashCore')
            self.assertFalse(report['passed'])


if __name__=='__main__':unittest.main()
