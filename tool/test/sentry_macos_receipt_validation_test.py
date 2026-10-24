"""Replay #125 metadata with synthetic Mach-O/source bytes; never an app build.

Captured inventory/receipt JSON retains its real schema/graph. Source proof
hashes are rebound to explicit test files because #125 did not retain sources.
This does NOT recreate the unavailable final app or prove its failing branch.
"""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock
TOOL=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(TOOL),str(TOOL/'test')]
import sentry_macos_inventory as inventory
import prepare_sentry_macos_symbols as preparation
from sentry_macos_symbols_test import macho


class ReceiptValidationTests(unittest.TestCase):
    def fixture(self,brand='OmoFly',arch='arm64'):
        tmp=tempfile.TemporaryDirectory(prefix='receipt-PRIVATE_MARKER-');self.addCleanup(tmp.cleanup)
        project=Path(tmp.name);build=project/'build'
        data=json.loads((TOOL/'test/fixtures/run125-macos-inventory.json').read_text())
        receipt=json.loads((TOOL/'test/fixtures/run125-macos-receipt.json').read_text())
        receipt['app']=receipt['app'].replace('OmoFly',brand)
        app=build/receipt['app'];(app/'Contents').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':brand}))
        for row in receipt['runtime']:
            row['binary']=row['binary'].replace('OmoFly',brand)
            variant=row['variants'][0];variant['architecture']=arch
            binary=build/row['binary'];binary.parent.mkdir(parents=True,exist_ok=True)
            binary.write_bytes(macho(variant['uuid'],arch,filetype=2 if row['target']=='runner' else 6))
        proof=next(x['linker_only'] for x in data['source_targets'] if 'linker_only' in x)
        package=project/proof['package_path'];package.mkdir(parents=True)
        (package/'Package.swift').write_text('// Offline evaluated manifest fixture.\n')
        for source in proof['sources']:
            path=package/source['path'];path.parent.mkdir(parents=True,exist_ok=True)
            raw=b'// Offline empty Swift linker helper.\n';path.write_bytes(raw)
            source.update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
        proof['manifest_sha256']=hashlib.sha256((package/'Package.swift').read_bytes()).hexdigest()
        raw=inventory.encoded(data);receipt['inventory_sha256']=hashlib.sha256(raw).hexdigest()
        (build/inventory.INVENTORY).write_bytes(raw)
        (build/inventory.RECEIPT).write_bytes(inventory.encoded(receipt))
        return build,app,package,receipt

    def report(self,build):
        result=json.loads((build/inventory.VALIDATION_REPORT).read_text())
        self.assertNotIn('PRIVATE_MARKER',json.dumps(result))
        return result

    def test_capture_shape_accepts_both_brands_and_architectures_without_rewriting_receipts(self):
        for brand in ['OmoFly','Daishu']:
            for arch in ['arm64','x86_64']:
                with self.subTest(brand=brand,arch=arch):
                    build,app,_,_=self.fixture(brand,arch)
                    original={p:(build/p).read_bytes() for p in (inventory.INVENTORY,inventory.RECEIPT)}
                    result=inventory.load_inventory(build,app)
                    self.assertEqual(result['products'],[]) # Legitimate statically linked SPM graph.
                    self.assertEqual(len(result['source_targets']),23)
                    self.assertEqual(self.report(build)['status'],'complete')
                    for p,raw in original.items():self.assertEqual((build/p).read_bytes(),raw)

    def test_distinct_failure_checks_replace_prior_success_and_preserve_strict_validation(self):
        for mode,check in [('inventory','inventory_read'),('receipt','receipt_read'),
                           ('digest','inventory_digest'),('app','app_identity'),('configuration','configuration'),
                           ('uuid','runtime_match'),('architecture','runtime_match'),('add','runtime_match'),('remove','runtime_match'),
                           ('plist','runtime_read'),('manifest','link_helper_manifest'),('source','link_helper_sources')]:
            for brand,arch in [(brand,arch) for brand in ['OmoFly','Daishu'] for arch in ['arm64','x86_64']]:
                with self.subTest(mode=mode,brand=brand,arch=arch):
                    build,app,package,receipt=self.fixture(brand,arch)
                    inventory.load_inventory(build,app)
                    if mode in ('inventory','receipt'):(build/(inventory.INVENTORY if mode=='inventory' else inventory.RECEIPT)).unlink()
                    elif mode in ('digest','app','configuration'):
                        receipt[{'digest':'inventory_sha256','app':'app','configuration':'configuration'}[mode]]='changed'
                        (build/inventory.RECEIPT).write_bytes(inventory.encoded(receipt))
                    elif mode=='uuid':
                        (app/'Contents/MacOS'/brand).write_bytes(macho('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',arch,filetype=2))
                    elif mode=='architecture':
                        row=next(row for row in receipt['runtime'] if row['target']=='runner')
                        (app/'Contents/MacOS'/brand).write_bytes(macho(row['variants'][0]['uuid'],'x86_64' if arch=='arm64' else 'arm64',filetype=2))
                    elif mode=='add':(app/'Contents/MacOS/extra').write_bytes(macho('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',arch,filetype=6))
                    elif mode=='remove':(app/'Contents/MacOS/FlClashCore').unlink()
                    elif mode=='plist':(app/'Contents/Info.plist').unlink()
                    elif mode=='manifest':(package/'Package.swift').write_text('// changed\n')
                    else:(package/'Sources/SentryCppHelper/SentryCppHelper.swift').write_text('// changed\n')
                    with self.assertRaises(inventory.InventoryError) as raised:inventory.load_inventory(build,app)
                    self.assertEqual(raised.exception.diagnostic['inventory_check'],check)
                    report=self.report(build);self.assertEqual(report['status'],'failed');self.assertEqual(report['inventory_check'],check)
                    if mode in ('uuid','architecture','add','remove'):
                        self.assertEqual(report[{'uuid':'changed_modules','architecture':'changed_modules','add':'added_modules','remove':'removed_modules'}[mode]],1)

    def test_preparation_cli_retains_inventory_reason_and_does_not_start_symbol_tool(self):
        build,app,_,_=self.fixture()
        (build/inventory.RECEIPT).unlink()
        error=io.StringIO()
        with contextlib.redirect_stderr(error),mock.patch.object(preparation.subprocess,'run') as run:
            self.assertEqual(preparation.main(['--build-root',str(build),'--dsymutil','not-called','--dwarfdump','not-called']),1)
        run.assert_not_called()
        self.assertIn('receipt_read',error.getvalue())
        self.assertNotIn('PRIVATE_MARKER',error.getvalue())
        report=json.loads((build/'macos/sentry-symbol-preparation.json').read_text())
        self.assertEqual(report['diagnostics'][0]['inventory_check'],'receipt_read')
        self.assertFalse((build/'sentry-native/macos/manifest.json').exists())

    def test_report_path_cannot_escape_build(self):
        build,app,_,_=self.fixture()
        outside=build.parent/'outside';outside.write_text('sentinel')
        (build/inventory.VALIDATION_REPORT).symlink_to(outside)
        with self.assertRaises(inventory.InventoryError):inventory.load_inventory(build,app)
        self.assertEqual(outside.read_text(),'sentinel')

    def test_unknown_diagnostic_fields_are_not_exposed(self):
        self.assertEqual(preparation.safe_diagnostic({'inventory_check':'secret=PRIVATE_MARKER','path':'PRIVATE_MARKER'}),{})


if __name__=='__main__':unittest.main()
