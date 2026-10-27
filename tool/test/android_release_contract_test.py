import json
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_android_release_contract as contract
from apk_archive import ApkArchive, ApkArchiveError
sys.path.insert(0, str(Path(__file__).resolve().parent))
from crisp_resource_fixture import resource_dump
from apk_archive_fixture import corrupt_zip_entry
from crisp_resource_inventory import inventory

class ContractTest(unittest.TestCase):
    def test_range_and_legacy_upgrade(self):
        for n in [1, 33, 38, 39, 999, 1001]:
            self.assertGreater(contract.version_code(n), 4000 + n)
            self.assertGreater(contract.version_code(n + 1), contract.version_code(n))
        self.assertEqual(contract.version_code(38), 1000038)
        self.assertEqual(contract.version_code(2099000000), 2100000000)
        for n in [0, -1, True, '38', 38.0, 2099000001]:
            with self.subTest(n=n), self.assertRaises(ValueError): contract.version_code(n)

    def test_apk_metadata_and_channel_negative_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'test.apk'
            for brand in ['com.cloud.app.omofly','com.cloud.app.daishu']:
                for abi in ['armeabi-v7a','arm64-v8a']:
                    def write(missing=None, wrong_aot=False):
                        with zipfile.ZipFile(p,'w') as z:
                            z.writestr('lib/'+abi+'/libapp.so', (brand+'/service').encode() if wrong_aot else b'fixture-aot')
                            z.writestr('classes.dex','\0'.join('com.follow.clash/'+s for s in contract.CHANNELS if s!=missing)+'\0')
                    write()
                    good=f"package: name='{brand}' versionCode='1000038'"
                    self.assertEqual(contract.verify(p,38,brand,'unused',badging=good,resources_dump=resource_dump(brand))['versionCode'],1000038)
                    with mock.patch.object(contract.subprocess, 'run', return_value=mock.Mock(stdout=resource_dump(brand).encode())) as command:
                        report=contract.verify(p,38,brand,'aapt-real-entry',badging=good)
                        self.assertTrue(report['crispResourcesVerified'])
                        self.assertEqual(command.call_args.args[0],['aapt-real-entry','dump','resources',str(p)])
                    for code in [38,1038,2038,1000037,1000039]:
                        with self.subTest(brand=brand,abi=abi,code=code), self.assertRaises(ValueError):
                            contract.verify(p,38,brand,'unused',badging=good.replace('1000038',str(code)),resources_dump=resource_dump(brand))
                    with self.assertRaises(ValueError):contract.verify(p,38,'wrong.package','unused',badging=good,resources_dump=resource_dump(brand))
                    write(wrong_aot=True)
                    with self.assertRaisesRegex(ValueError, 'Dart uses branded'):contract.verify(p,38,brand,'unused',badging=good,resources_dump=resource_dump(brand))
                    for suffix in contract.CHANNELS:
                        write(suffix)
                        with self.subTest(suffix=suffix), self.assertRaises(ValueError):contract.verify(p,38,brand,'unused',badging=good,resources_dump=resource_dump(brand))

    def test_metadata_failure_diagnostics_and_stale_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apk, report = root / 'test.apk', root / 'report.json'
            with zipfile.ZipFile(apk, 'w') as z:
                z.writestr('lib/arm64-v8a/libapp.so', b'fixture-aot')
                z.writestr('classes.dex', '\0'.join('com.follow.clash/' + s for s in contract.CHANNELS) + '\0')
            for brand in ['com.cloud.app.omofly', 'com.cloud.app.daishu']:
                good = f"package: name='{brand}' versionCode='1000038' versionName='0.9.1'"
                contract.verify(apk, 38, brand, 'unused', badging=good,
                                resources_dump=resource_dump(brand), diagnostic_path=report)
                self.assertTrue(json.loads(report.read_text())['passed'])
                for bad in [good.replace('1000038', '2038'), good.replace(brand, 'wrong.package'), '']:
                    with self.assertRaisesRegex(ValueError, 'APK metadata mismatch') as error:
                        contract.verify(apk, 38, brand, 'unused', badging=bad, diagnostic_path=report)
                    evidence = json.loads(report.read_text())
                    self.assertFalse(evidence['passed'])
                    self.assertEqual(evidence['expected']['versionCode'], 1000038)
                    self.assertEqual(evidence['expected']['package'], brand)
                    self.assertIn('expected', str(error.exception))
                    self.assertIn('actual', str(error.exception))
                    self.assertEqual(evidence['actual']['versionCode'], '2038' if '2038' in bad else '1000038' if bad else '<missing>')
                # Tool failures also replace earlier evidence, without raw tool output.
                failure = contract.subprocess.CalledProcessError(1, ['aapt'], stderr=b'private-output')
                with mock.patch.object(contract.subprocess, 'run', side_effect=failure), self.assertRaises(contract.subprocess.CalledProcessError):
                    contract.verify(apk, 38, brand, 'aapt', diagnostic_path=report)
                evidence = report.read_text()
                self.assertNotIn('private-output', evidence)
                self.assertFalse(json.loads(evidence)['passed'])
                self.assertIsNone(json.loads(evidence)['actual'])

    def test_ci_entry_diagnoses_both_apks_before_failing(self):
        for brand in ['com.cloud.app.omofly', 'com.cloud.app.daishu']:
            with self.subTest(brand=brand), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'build').mkdir()
                (root / 'dist').mkdir()
                (root / 'build/release-context.json').write_text(json.dumps({'platform': 'android', 'build_number': 38}))
                (root / 'flavor_defines.json').write_text(json.dumps({'XB_NATIVE_ID': brand}))
                for abi in ['armeabi-v7a', 'arm64-v8a']:
                    (root / 'dist' / (abi + '.apk')).touch()
                bad = f"package: name='{brand}' versionCode='2038'"
                with mock.patch.object(contract, 'ROOT', root), mock.patch.object(contract, 'find_aapt', return_value='aapt'), mock.patch.object(contract.subprocess, 'run', return_value=mock.Mock(stdout=bad.encode())), self.assertRaisesRegex(ValueError, 'APK metadata mismatch'):
                    contract.main()
                reports = list((root / 'build/android-release-contract').glob('*.json'))
                self.assertEqual(len(reports), 2)
                self.assertTrue(all(json.loads(p.read_text())['actual']['versionCode'] == '2038' for p in reports))
        workflow = (contract.ROOT / '.github/workflows/release-package.yml').read_text()
        self.assertIn('            build/android-release-contract/', workflow)

    def test_ci_corrupt_apk_does_not_skip_other_package(self):
        for brand in ['com.cloud.app.omofly', 'com.cloud.app.daishu']:
            for corrupt in [(), ('a.apk',), ('b.apk',), ('a.apk', 'b.apk')]:
                with self.subTest(brand=brand, corrupt=corrupt), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / 'build').mkdir()
                    (root / 'dist').mkdir()
                    (root / 'build/release-context.json').write_text(json.dumps({'platform': 'android', 'build_number': 38}))
                    (root / 'flavor_defines.json').write_text(json.dumps({'XB_NATIVE_ID': brand}))
                    for name, abi in [('a.apk', 'armeabi-v7a'), ('b.apk', 'arm64-v8a')]:
                        apk = root / 'dist' / name
                        if name in corrupt:
                            apk.write_bytes(b'corrupt ZIP')
                        else:
                            with zipfile.ZipFile(apk, 'w') as z:
                                z.writestr('lib/' + abi + '/libapp.so', b'fixture')
                                z.writestr('classes.dex', '\0'.join('com.follow.clash/' + s for s in contract.CHANNELS) + '\0')
                    def aapt(command, **kwargs):
                        text = (f"package: name='{brand}' versionCode='1000038'"
                                if command[2] == 'badging' else resource_dump(brand))
                        return mock.Mock(stdout=text.encode())
                    with mock.patch.object(contract, 'ROOT', root), mock.patch.object(contract, 'find_aapt', return_value='aapt'), mock.patch.object(contract.subprocess, 'run', side_effect=aapt):
                        if corrupt:
                            with self.assertRaises(ApkArchiveError): contract.main()
                        else:
                            contract.main()
                    for name in ['a.apk', 'b.apk']:
                        report = json.loads((root / 'build/android-release-contract' / (name + '.json')).read_text())
                        self.assertEqual(report['passed'], name not in corrupt)
                        self.assertEqual(report['scope'], 'android-contract')
                        if name in corrupt: self.assertEqual(report['failureType'], 'ApkArchiveError')

    def test_compressed_payload_errors_continue_and_recover(self):
        for brand in ['com.cloud.app.omofly', 'com.cloud.app.daishu']:
            for mode, cause in [('deflate', 'error'), ('crc', 'BadZipFile'), ('unsupported', 'NotImplementedError'), ('encrypted', 'RuntimeError')]:
                for target in ['classes.dex', 'lib/arm64-v8a/libapp.so']:
                    with self.subTest(brand=brand, mode=mode, target=target), tempfile.TemporaryDirectory() as directory:
                        root = Path(directory)
                        (root / 'build').mkdir()
                        (root / 'dist').mkdir()
                        (root / 'build/release-context.json').write_text(json.dumps({'platform': 'android', 'build_number': 38}))
                        (root / 'flavor_defines.json').write_text(json.dumps({'XB_NATIVE_ID': brand}))
                        for name in ['a.apk', 'b.apk']:
                            with zipfile.ZipFile(root / 'dist' / name, 'w', compression=zipfile.ZIP_DEFLATED) as z:
                                z.writestr('lib/arm64-v8a/libapp.so', b'fixture-aot')
                                z.writestr('classes.dex', '\0'.join('com.follow.clash/' + x for x in contract.CHANNELS) + '\0')
                        first = root / 'dist/a.apk'
                        original = first.read_bytes()
                        corrupt_zip_entry(first, target, mode)
                        # Verify the fault uses actual archive/decompression code.
                        with self.assertRaises(ApkArchiveError) as fault:
                            with ApkArchive(first) as archive: archive.read(target)
                        self.assertEqual(type(fault.exception.__cause__).__name__, cause)
                        def aapt(command, **kwargs):
                            return mock.Mock(stdout=(f"package: name='{brand}' versionCode='1000038'"
                                if command[2] == 'badging' else resource_dump(brand)).encode())
                        with mock.patch.object(contract, 'ROOT', root), mock.patch.object(contract, 'find_aapt', return_value='aapt'), mock.patch.object(contract.subprocess, 'run', side_effect=aapt):
                            with self.assertRaises(ApkArchiveError): contract.main()
                            reports = root / 'build/android-release-contract'
                            self.assertFalse(json.loads((reports / 'a.apk.json').read_text())['passed'])
                            self.assertTrue(json.loads((reports / 'b.apk.json').read_text())['passed'])
                            first.write_bytes(original)
                            contract.main()
                            for name in ['a.apk.json', 'b.apk.json']:
                                report = json.loads((reports / name).read_text())
                                self.assertTrue(report['passed'])
                                self.assertNotIn('failureType', report)

    def test_archive_boundary_does_not_swallow_caller_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'valid.apk'
            with zipfile.ZipFile(path, 'w') as archive: archive.writestr('x', b'x')
            error = RuntimeError('caller bug')
            with self.assertRaises(RuntimeError) as caught:
                with ApkArchive(path): raise error
            self.assertIs(caught.exception, error)

    def test_each_resource_family_missing_wrong_package_and_spec_only(self):
        for package in ['com.cloud.app.omofly','com.cloud.app.daishu']:
            good=resource_dump(package)
            self.assertEqual(contract.verify_crisp_resources(good,package),1295)
            for family in ['bool','color','drawable','raw','string','style']:
                bad='\n'.join(line for line in good.splitlines() if ':'+family+'/' not in line)
                with self.subTest(package=package,family=family),self.assertRaises(ValueError):
                    contract.verify_crisp_resources(bad,package)
            for bad in [good.replace(package,'wrong.package'),good.replace('resource ','spec resource '),
                        good.replace('t=0x12','t=0x00').replace('<bag>','<null>'),
                        good.replace('bool/crisp_is_rtl:', 'bool/crisp_is_rtl_suffix:'),
                        __import__('re').sub(r'resource 0x[0-9a-f]+', 'resource 0x00000000', good), '']:
                with self.assertRaises(ValueError):contract.verify_crisp_resources(bad,package)
            # False is a valid bool value, not a missing resource.
            self.assertIn('bool/crisp_is_rtl: t=0x12 d=0x00000000',good)
            self.assertIn('string/crisp_sdk_audio_speed_1.5:',good)

    def test_null_references_and_legitimate_zero_values(self):
        for kind in [0x10,0x11,0x12,0x1c,0x1d,0x1e,0x1f,0x03]:
            self.assertTrue(contract.resource_value_is_usable(f't=0x{kind:02x} d=0x00000000'))
        for kind in [1,2,7,8]:
            self.assertTrue(contract.resource_value_is_usable(f't=0x{kind:02x} d=0x0106000d'))
        for package in ['com.cloud.app.omofly','com.cloud.app.daishu']:
            good=resource_dump(package)
            original=next(line for line in good.splitlines() if ':bool/crisp_is_rtl:' in line)
            for kind,data in [(0,0),(0,1),(1,0),(2,0),(7,0),(8,0)]:
                wrong=original.replace('t=0x12 d=0x00000000',f't=0x{kind:02x} d=0x{data:08x}')
                for candidate in [good.replace(original,wrong), good+'\n'+wrong, wrong+'\n'+good]:
                    with self.subTest(package=package,kind=kind,data=data),self.assertRaisesRegex(ValueError,'bool/crisp_is_rtl'):
                        contract.verify_crisp_resources(candidate,package)
            self.assertEqual(contract.verify_crisp_resources(good,package),1295)

    def test_application_alias_chains(self):
        for package in ['com.cloud.app.omofly','com.cloud.app.daishu']:
            good=resource_dump(package)
            original=next(line for line in good.splitlines() if ':bool/crisp_is_rtl:' in line)
            alias=original.replace('t=0x12 d=0x00000000','t=0x01 d=0x7fef0001')
            base=good.replace(original,alias)
            def entry(identifier,value):
                return f'\n resource 0x{identifier:08x} {package}:bool/test_alias_{identifier:x}: {value}'
            for value in ['t=0x12 d=0x00000000','t=0x12 d=0xffffffff','t=0x1c d=0x00000000','t=0x01 d=0x0106000d']:
                self.assertEqual(contract.verify_crisp_resources(base+entry(0x7fef0001,value),package),1295)
            for extra in ['',entry(0x7fef0001,'t=0x01 d=0x00000000'),
                          entry(0x7fef0001,'t=0x00 d=0x00000001'),
                          entry(0x7fef0001,'t=0x01 d=0x7fef0001'),
                          entry(0x7fef0001,'t=0x01 d=0x7fef0002')+entry(0x7fef0002,'t=0x01 d=0x7fef0001')]:
                with self.subTest(package=package,extra=extra),self.assertRaisesRegex(ValueError,'bool/crisp_is_rtl'):
                    contract.verify_crisp_resources(base+extra,package)
            # A second resource configuration cannot conceal the null target.
            mixed=entry(0x7fef0001,'t=0x12 d=0x00000000')+entry(0x7fef0001,'t=0x01 d=0x00000000')
            with self.assertRaises(ValueError):contract.verify_crisp_resources(base+mixed,package)
            # Unreachable application resources are outside this contract.
            self.assertEqual(contract.verify_crisp_resources(good+entry(0x7fef9999,'t=0x01 d=0x00000000'),package),1295)
            colors=[line for line in good.splitlines() if ':color/' in line][:2]
            shared=good
            for color in colors:shared=shared.replace(color,color.replace('t=0x12 d=0x00000000','t=0x01 d=0x7fef0001'))
            self.assertEqual(contract.verify_crisp_resources(shared+entry(0x7fef0001,'t=0x1c d=0x00000000'),package),1295)
            # Long chains finish without recursion limits.
            chain=''.join(entry(n,f't=0x07 d=0x{n+1:08x}') for n in range(0x7fef0001,0x7fef0501))
            chain+=entry(0x7fef0501,'t=0x12 d=0x00000000')
            self.assertEqual(contract.verify_crisp_resources(base+chain,package),1295)
            chain_bad=chain.replace('t=0x12 d=0x00000000','t=0x01 d=0x00000000')
            with self.assertRaises(ValueError):contract.verify_crisp_resources(base+chain_bad,package)

    def test_day_night_fallback_and_real_cycles(self):
        for package in ['com.cloud.app.omofly','com.cloud.app.daishu']:
            good=resource_dump(package)
            original=next(line for line in good.splitlines() if ':bool/crisp_is_rtl:' in line)
            root_id=int(original.split()[1],16)
            def row(identifier,name,value):return f'\n resource 0x{identifier:08x} {package}:bool/{name}: {value}'
            root_ref=original.replace('t=0x12 d=0x00000000','t=0x01 d=0x7fef0001')
            helper_false=row(0x7fef0001,'xb_cross','t=0x12 d=0x00000000')
            helper_ref=row(0x7fef0001,'xb_cross',f't=0x01 d=0x{root_id:08x}')
            helper_true=row(0x7fef0001,'xb_cross','t=0x12 d=0xffffffff')
            helper_null=row(0x7fef0001,'xb_cross','t=0x01 d=0x00000000')
            for default_helper in [helper_ref,helper_null,helper_false]:
                text='config (default):\n'+good+default_helper+'\nconfig night-v8:\n'+root_ref+helper_true
                self.assertEqual(contract.verify_crisp_resources(text,package),1295)
            # Default source keeps the NIGHT context when resolving its target.
            text='config (default):\n'+good.replace(original,root_ref)+helper_false+'\nconfig night-v8:\n'+helper_true
            self.assertEqual(contract.verify_crisp_resources(text,package),1295)
            # A night source can fall back to a default target.
            text='config (default):\n'+good+helper_false+'\nconfig night-v8:\n'+root_ref
            self.assertEqual(contract.verify_crisp_resources(text,package),1295)
            for bad in [helper_ref,helper_null]:
                text='config (default):\n'+good+helper_false+'\nconfig night-v8:\n'+root_ref+bad
                with self.assertRaisesRegex(ValueError,'bool/crisp_is_rtl'):contract.verify_crisp_resources(text,package)
            text='config (default):\n'+good+helper_null+'\nconfig night-v8:\n'+root_ref
            with self.assertRaises(ValueError):contract.verify_crisp_resources(text,package)

    def test_configuration_priorities_versions_and_uncertain_qualifiers(self):
        context=dict(direction='rtl',orientation='land',night=True,version=31)
        values={'(default)':'t=0x12 d=0x0','night-v8':'t=0x01 d=0x7f010001','ldrtl-v17':'t=0x01 d=0x7f010002'}
        self.assertIn('7f010002',contract.select_resource_value(values,context))
        self.assertIn('7f010001',contract.select_resource_value(values,{**context,'direction':'ltr'}))
        self.assertEqual(contract.select_resource_value({'(default)':'t=0x12 d=0x0','v35':'t=0x01 d=0x0'},context),'t=0x12 d=0x0')
        self.assertIsNone(contract.select_resource_value({'night-v8':'t=0x01 d=0x7f010001','v35':'t=0x12 d=0x0'}, {**context,'night':False}))
        self.assertIsNone(contract.select_resource_value({'night-v8':'t=0x12 d=0x0'}, {**context,'night':False}))
        self.assertIsNone(contract.select_resource_value({'v35':'t=0x12 d=0x0'},context))
        self.assertEqual(contract.select_resource_value({'mdpi-v4':'t=0x03 d=0x1','xhdpi-v4':'t=0x03 d=0x2'},context),'t=0x03 d=0x1')
        self.assertIsNone(contract.select_resource_value({'anydpi-v35':'t=0x03 d=0x1'},context))
        with self.assertRaises(contract.ResourceConfigurationUncertain):
            contract.select_resource_value({'(default)':'t=0x12 d=0x0','ar':'t=0x01 d=0x0'},context)
        self.assertEqual(contract.select_resource_value({'(default)':'t=0x12 d=0x0','ar':'t=0x12 d=0x1'},context),'t=0x12 d=0x0')

    def test_exact_runtime_names_not_just_r_identifiers(self):
        pairs=[(key,value) for key,value in contract.CRISP_CONTRACT['resources'].items() if key.split('/')[1]!=value]
        self.assertEqual(len(pairs),42)
        for package in ['com.cloud.app.omofly','com.cloud.app.daishu']:
            good=resource_dump(package)
            for identifier,runtime in pairs:
                kind,canonical=identifier.split('/')
                token=kind+'/'+runtime+':'
                for wrong in [canonical,runtime.replace('.', '_',1)]:
                    with self.subTest(package=package,identifier=identifier,wrong=wrong),self.assertRaises(ValueError):
                        contract.verify_crisp_resources(good.replace(token,kind+'/'+wrong+':'),package)
                missing='\n'.join(line for line in good.splitlines() if token not in line)
                with self.assertRaises(ValueError):contract.verify_crisp_resources(missing,package)
            self.assertEqual(contract.verify_crisp_resources(good,package),1295)

    def test_mapping_rejects_invalid_schema_and_inconsistent_names(self):
        for mapping in [[],{}, {'bool/crisp_is_rtl':'different_name'}, {'bool/crisp_is_rtl':'crisp_is_rtl/extra'}]:
            with self.assertRaises(ValueError):contract.validate_crisp_contract({'schema_version':2,'resources':mapping})
        with self.assertRaises(ValueError):contract.validate_crisp_contract({'schema_version':1,'resources':{'bool/crisp_is_rtl':'crisp_is_rtl'}})

    def test_inventory_uses_source_names_and_rejects_ambiguous_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            aar=Path(tmp)/'fixture.aar'
            def make(xml):
                with zipfile.ZipFile(aar,'w') as z:
                    z.writestr('R.txt','int string crisp_test_1_5 0x0\n')
                    z.writestr('res/values/values.xml',xml)
                return hashlib.sha256(aar.read_bytes()).hexdigest()
            digest=make('<resources><string name="crisp_test_1.5">value</string></resources>')
            self.assertEqual(inventory(aar,digest),{'string/crisp_test_1_5':'crisp_test_1.5'})
            with self.assertRaisesRegex(ValueError,'checksum'):inventory(aar,'0'*64)
            for xml in ['<resources />','<resources><string name="crisp_test_1.5">a</string><string name="crisp_test_1_5">b</string></resources>']:
                digest=make(xml)
                with self.assertRaisesRegex(ValueError,'Missing or ambiguous'):inventory(aar,digest)

    def test_sdk_pin_matches_resource_inventory(self):
        gradle=(contract.ROOT/'plugins/crisp_chat/android/build.gradle').read_text()
        self.assertIn('im.crisp:crisp-sdk:'+contract.CRISP_CONTRACT['sdk_version'],gradle)
        self.assertIn('bool/crisp_is_rtl',contract.CRISP_CONTRACT['resources'])
        self.assertEqual(len(contract.CRISP_CONTRACT['resources']),len(set(contract.CRISP_CONTRACT['resources'])))

if __name__=='__main__':unittest.main()
