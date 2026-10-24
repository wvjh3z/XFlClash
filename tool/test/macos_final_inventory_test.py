"""Post-package receipt lifecycle, real metadata/Mach-O fixtures, no app build."""
import contextlib
import json
import plistlib
from pathlib import Path
import sys
import unittest
from unittest import mock
sys.path[:0]=[str(Path(__file__).resolve().parents[1]),str(Path(__file__).resolve().parent)]
import release_pipeline as pipeline
import sentry_macos_inventory as inventory
import prepare_sentry_macos_symbols as preparation
import sentry_macos_spm_inventory_test as spm
from sentry_macos_symbols_test import macho
from sentry_macho import inspect_macho
from release_pipeline_test import context


class FinalInventoryTests(unittest.TestCase):
    def fixture(self,brand,arch):
        f=spm.SpmInventoryTests();f.setUp();self.addCleanup(f.doCleanups)
        old=f.app;f.app=old.with_name(brand+'.app');old.rename(f.app)
        (f.app/'Contents/MacOS/Fixture').rename(f.app/'Contents/MacOS'/brand)
        (f.app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':brand}))
        for name in ['App','FlutterMacOS','rust_api','FlClashCore','objective_c']:f.add_module(name)
        for p in f.app.rglob('*'):
            if p.is_file() and p.name!='Info.plist':
                info=inspect_macho(p)['variants'][0]
                p.write_bytes(macho(info['uuid'],arch,filetype=info['filetype']))
        vendor=f.app/'Contents/Frameworks/VendorBinary.framework/VendorBinary'
        f.vendor_library.write_bytes(vendor.read_bytes())
        info=plistlib.loads((f.vendor_root/'Info.plist').read_bytes())
        info['AvailableLibraries'][0]['SupportedArchitectures']=[arch]
        (f.vendor_root/'Info.plist').write_bytes(plistlib.dumps(info))
        return f

    def test_both_brands_and_architectures_record_ten_final_modules_and_reject_later_mutation(self):
        for brand in ['OmoFly','Daishu']:
            for arch in ['arm64','x86_64']:
                with self.subTest(brand=brand,arch=arch):
                    f=self.fixture(brand,arch)
                    with mock.patch.object(inventory,'linked_packages',return_value=inventory.LinkGraph(f.links,[str(f.cp)])), \
                         mock.patch.object(inventory.PackageGraph,'dump',side_effect=lambda path:json.loads((path/'dump.json').read_text())):
                        inventory.collect_inventory(f.project,f.build,f.app,pods_root=f.pods)
                        old=json.loads((f.build/inventory.RECEIPT).read_text())
                        self.assertEqual(len(old['runtime']),8)
                        # Synthetic late additions; do not claim these names are #126's unrecorded libraries.
                        for name in ['late_a','late_b']:
                            p=f.add_module(name);info=inspect_macho(p)['variants'][0]
                            p.write_bytes(macho(info['uuid'],arch,filetype=6))
                        with self.assertRaises(inventory.InventoryError):inventory.load_inventory(f.build,f.app)
                        pipeline.record_final_macos_inventory(f.project)
                        final=json.loads((f.build/inventory.RECEIPT).read_text())
                        self.assertEqual(len(final['runtime']),10)
                        for row in old['runtime']:self.assertIn(row,final['runtime'])
                        inventory.load_inventory(f.build,f.app)
                        bytes_before=(f.build/inventory.RECEIPT).read_bytes()
                        f.add_module('after_receipt')
                        with self.assertRaises(inventory.InventoryError):inventory.load_inventory(f.build,f.app)
                        self.assertEqual((f.build/inventory.RECEIPT).read_bytes(),bytes_before)

    def test_failed_new_collection_invalidates_prior_receipt(self):
        f=self.fixture('Daishu','arm64')
        for name in (inventory.INVENTORY,inventory.RECEIPT):(f.build/name).write_text('{}')
        with mock.patch.object(inventory,'collect_inventory',side_effect=inventory.InventoryError('controlled')):
            with self.assertRaisesRegex(pipeline.PipelineError,'final_inventory_failed'):
                pipeline.record_final_macos_inventory(f.project)
        for name in (inventory.INVENTORY,inventory.RECEIPT):self.assertFalse((f.build/name).exists())

    def test_formal_package_entry_records_only_after_success_and_never_on_other_platforms(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);path=root/'context.json'
            for brand in ['brand_a','brand_b']:
                for platform,arch in [('macos','arm64'),('macos','amd64'),('windows','amd64'),('linux','amd64'),('android','')]:
                    for code in [0,7]:
                        events=[];path.write_text(json.dumps(context(platform,arch,flavor=brand)))
                        def process(*args,**kwargs):events.append('package');return mock.Mock(returncode=code)
                        def record(*args):events.append('inventory')
                        with mock.patch('verify_brand_identity.verify'),mock.patch.object(pipeline.shutil,'which',return_value='dart'), \
                             mock.patch.object(pipeline.subprocess,'run',side_effect=process),mock.patch.object(pipeline,'record_final_macos_inventory',side_effect=record):
                            self.assertEqual(pipeline.main(['package','--context',str(path),'--dist',str(root/'dist')]),code)
                        self.assertEqual(events,['package','inventory'] if code==0 and platform=='macos' else ['package'])

    def test_xcode_no_longer_records_intermediate_receipt(self):
        source=(Path(__file__).resolve().parents[2]/'macos/Runner.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('Record Sentry Native Inventory',source)
        self.assertNotIn('sentry_macos_inventory.py',source)


if __name__=='__main__':unittest.main()
