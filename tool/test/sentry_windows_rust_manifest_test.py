#!/usr/bin/env python3
"""CMake declarations plus Native Assets handoff; no Windows client compilation."""
import io
import contextlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_sentry_windows_assets import prepare_windows_assets
from upload_sentry_symbols import SymbolError
from sentry_hook_inputs import rust_inputs
import postbuild_sentry_symbols as postbuild
import upload_sentry_symbols as uploader

HELPER = Path(__file__).resolve().parents[2] / 'windows/xboard_sentry_symbols.cmake'


class RustManifestTests(unittest.TestCase):
    def fixture(self, parent=None):
        temp=tempfile.TemporaryDirectory(prefix='sentry-rust-中文-', dir=parent);self.addCleanup(temp.cleanup)
        root=Path(temp.name);build=root/'build';bundle=build/'windows/x64/runner/Release';bundle.mkdir(parents=True)
        for name in ['FlClash.exe','rust_api.dll','FlClashHelperService.exe']:(bundle/name).write_bytes(b'matching')
        manifest=build/'windows/x64/sentry-symbols/Release/targets.tsv';manifest.parent.mkdir(parents=True)
        manifest.write_text(f'FlClash\t{bundle/"FlClash.exe"}\t{bundle/"FlClash.pdb"}\n',encoding='utf-8')
        hook=build/'sentry-hook-inputs/windows/x64';hook.mkdir(parents=True)
        (hook/'rust_api.dll').write_bytes(b'matching');(hook/'rust_api.pdb').write_bytes(b'matching')
        (hook/'manifest.json').write_text(json.dumps({'schema_version':1,'platform':'windows','architecture':'x64','binary':'rust_api.dll','companions':['rust_api.pdb']}))
        helper=root/'services/helper/target/x86_64-pc-windows-msvc/release/helper.pdb';helper.parent.mkdir(parents=True);helper.write_bytes(b'matching')
        return build,bundle,hook,manifest

    def check(self, cli, path, kind):
        return {'debug_ids':[path.read_bytes().decode('ascii')], 'architectures':['x86_64']}

    def assert_companions_inside(self, rows, build):
        # Windows short names/junctions and macOS /var aliases identify the
        # same directory. Compare physical paths on BOTH sides, not spelling.
        root = build.resolve(strict=True)
        self.assertTrue(all(Path(row[2]).resolve().is_relative_to(root) for row in rows))

    def test_real_postbuild_handoff_is_idempotent_and_copies_helper(self):
        build,bundle,hook,manifest=self.fixture()
        with mock.patch('prepare_sentry_windows_assets.check_symbol',side_effect=self.check):
            prepare_windows_assets(build,'fixture-cli');first=manifest.read_bytes()
            prepare_windows_assets(build,'fixture-cli')
        self.assertEqual(first,manifest.read_bytes())
        rows=[row.split('\t') for row in first.decode().splitlines()]
        self.assertEqual({r[0] for r in rows},{'FlClash','rust_api','FlClashHelperService'})
        self.assert_companions_inside(rows, build)
        self.assertEqual((build/'sentry-hook-inputs/windows/helper/helper.pdb').read_bytes(),b'matching')

    def test_real_directory_alias_and_escape_negative_control(self):
        temp=tempfile.TemporaryDirectory(prefix='sentry-alias-');self.addCleanup(temp.cleanup)
        root=Path(temp.name);real=root/'real';real.mkdir();alias=root/'alias'
        if os.name=='nt':
            subprocess.run(['cmd','/d','/c','mklink','/J',str(alias),str(real)],
                           check=True,capture_output=True,timeout=30)
            self.addCleanup(os.rmdir,alias)
        else:
            alias.symlink_to(real,target_is_directory=True)
        for brand in ('OmoFly','Daishu'):
            with self.subTest(brand=brand):
                build,bundle,hook,manifest=self.fixture(alias)
                (bundle/'FlClash.exe').rename(bundle/(brand+'.exe'))
                (bundle/'FlClashHelperService.exe').rename(bundle/(brand+'HelperService.exe'))
                manifest.write_text(f'{brand}\t{bundle/(brand+".exe")}\t{bundle/(brand+".pdb")}\n',encoding='utf-8')
                with mock.patch('prepare_sentry_windows_assets.check_symbol',side_effect=self.check):
                    prepare_windows_assets(build,'fixture-cli');first=manifest.read_bytes()
                    prepare_windows_assets(build,'fixture-cli')
                self.assertEqual(first,manifest.read_bytes())
                rows=[row.split('\t') for row in first.decode().splitlines()]
                self.assertFalse(all(Path(row[2]).is_relative_to(build) for row in rows),
                                 'Old lexical comparison must reject a valid alias')
                self.assert_companions_inside(rows,build)
                outside=root/'outside.pdb';outside.write_bytes(b'matching')
                with self.assertRaises(AssertionError):
                    self.assert_companions_inside([['escaped','unused',str(outside)]],build)

    @unittest.skipUnless(os.name=='nt', '8.3 aliases require native Windows')
    def test_native_windows_short_paths_for_both_brands(self):
        import ctypes
        from ctypes import wintypes
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.GetShortPathNameW.argtypes=[wintypes.LPCWSTR,wintypes.LPWSTR,wintypes.DWORD]
        kernel.GetShortPathNameW.restype=wintypes.DWORD
        for brand in ('OmoFly','Daishu'):
            build,bundle,hook,manifest=self.fixture()
            source=str(build.resolve(strict=True))
            size=kernel.GetShortPathNameW(source,None,0)
            if not size:raise ctypes.WinError(ctypes.get_last_error())
            buffer=ctypes.create_unicode_buffer(size)
            count=kernel.GetShortPathNameW(source,buffer,size)
            if not count or count>=size:raise ctypes.WinError(ctypes.get_last_error())
            short=Path(buffer.value)
            if str(short).casefold()==source.casefold():
                self.skipTest('8.3 aliases unavailable on this volume; junction regression is separate')
            self.assertTrue(os.path.samefile(short,build))
            (bundle/'FlClash.exe').rename(bundle/(brand+'.exe'))
            (bundle/'FlClashHelperService.exe').rename(bundle/(brand+'HelperService.exe'))
            manifest.write_text(f'{brand}\t{bundle/(brand+".exe")}\t{bundle/(brand+".pdb")}\n',encoding='utf-8')
            with mock.patch('prepare_sentry_windows_assets.check_symbol',side_effect=self.check):
                prepare_windows_assets(short,'fixture-cli');first=manifest.read_bytes()
                prepare_windows_assets(short,'fixture-cli')
            self.assertEqual(first,manifest.read_bytes())
            self.assert_companions_inside([r.split('\t') for r in first.decode().splitlines()],short)

    def test_both_brand_executable_names_preserve_logical_symbol_roles(self):
        for brand in ('OmoFly','Daishu'):
            with self.subTest(brand=brand):
                build,bundle,hook,manifest=self.fixture()
                (bundle/'FlClash.exe').rename(bundle/(brand+'.exe'))
                (bundle/'FlClashHelperService.exe').rename(bundle/(brand+'HelperService.exe'))
                manifest.write_text(f'{brand}\t{bundle/(brand+".exe")}\t{bundle/(brand+".pdb")}\n',encoding='utf-8')
                with mock.patch('prepare_sentry_windows_assets.check_symbol',side_effect=self.check):
                    prepare_windows_assets(build,'fixture-cli')
                    first=manifest.read_bytes()
                    prepare_windows_assets(build,'fixture-cli')
                self.assertEqual(first,manifest.read_bytes())
                text=manifest.read_text(encoding='utf-8')
                self.assertTrue(text.startswith('FlClash\t'))
                self.assertIn(brand+'HelperService.exe',text)
                self.assertNotIn('FlClash.exe',text)

    def test_missing_or_wrong_runtime_and_pdb_fail_before_success(self):
        for mode in ('missing_pdb','wrong_pdb','wrong_runtime','missing_helper'):
            with self.subTest(mode=mode):
                build,bundle,hook,manifest=self.fixture();before=manifest.read_bytes()
                if mode=='missing_pdb':(hook/'rust_api.pdb').unlink()
                if mode=='wrong_pdb':(hook/'rust_api.pdb').write_bytes(b'wrong')
                if mode=='wrong_runtime':(bundle/'rust_api.dll').write_bytes(b'wrong')
                if mode=='missing_helper':(bundle/'FlClashHelperService.exe').unlink()
                with mock.patch('prepare_sentry_windows_assets.check_symbol',side_effect=self.check),self.assertRaises((SymbolError,ValueError)):
                    prepare_windows_assets(build,'fixture-cli')
                self.assertEqual(manifest.read_bytes(),before)

    def test_matching_debug_id_with_wrong_architecture_is_rejected(self):
        build,bundle,hook,manifest=self.fixture()
        def wrong_arch(cli,path,kind):
            info=self.check(cli,path,kind)
            if path.name=='rust_api.pdb':info['architectures']=['arm64']
            return info
        with mock.patch('prepare_sentry_windows_assets.check_symbol',side_effect=wrong_arch),self.assertRaisesRegex(SymbolError,'architecture'):
            prepare_windows_assets(build,'fixture-cli')

    def test_real_prepare_reports_malformed_manifests_for_both_brands(self):
        valid={'schema_version':1,'platform':'windows','architecture':'x64','binary':'rust_api.dll','companions':['rust_api.pdb']}
        bad=[None, [], True, 23, 'SENSITIVE_FIXTURE_VALUE',
             {**valid,'schema_version':True}, {**valid,'architecture':[]},
             {**valid,'binary':{'private':'SENSITIVE_FIXTURE_VALUE'}},
             {**valid,'companions':42}, {**valid,'companions':None},
             {**valid,'companions':'rust_api.pdb'}, {**valid,'companions':{}},
             {**valid,'companions':[None]}, {**valid,'companions':[[]]},
             {**valid,'companions':['rust_api.pdb','rust_api.pdb']},
             {**valid,'companions':['../SENSITIVE_FIXTURE_VALUE']}]
        for brand in ('brand_a','brand_b'):
            for value in bad:
                with self.subTest(brand=brand,value_type=type(value).__name__):
                    build,bundle,hook,manifest=self.fixture();before=manifest.read_bytes()
                    root=build.parent
                    (root/'flavor_defines.json').write_text(json.dumps({'XB_FLAVOR_ID':brand,'XB_DEBUG':'false','XB_SENTRY_DSN':'fixture'}),encoding='utf-8')
                    (hook/'manifest.json').write_text(json.dumps(value),encoding='utf-8')
                    evidence=build/'sentry-symbols-evidence.json';evidence.write_text('{"status":"uploaded_and_processed"}',encoding='utf-8')
                    error=io.StringIO()
                    with mock.patch.object(postbuild,'resolve_cli',return_value='fixture'), \
                         mock.patch('prepare_sentry_windows_assets.check_symbol') as symbol, \
                         mock.patch.object(postbuild,'run_checked') as upload, contextlib.redirect_stderr(error):
                        code=postbuild.main(['--project-root',str(root),'--platform','windows','--flavor',brand,'--audit-only'])
                    self.assertEqual(code,1)
                    data=json.loads(evidence.read_text(encoding='utf-8'))
                    self.assertEqual((data['status'],data['postbuild_stage']),('failed','prepare'))
                    self.assertEqual(data['postbuild_error'],'ValueError')
                    self.assertEqual(manifest.read_bytes(),before)
                    self.assertNotIn('SENSITIVE_FIXTURE_VALUE',error.getvalue()+evidence.read_text())
                    self.assertNotIn('Traceback',error.getvalue())
                    symbol.assert_not_called();upload.assert_not_called()

    def test_valid_prepare_reaches_offline_audit_for_both_brands(self):
        for brand in ('brand_a','brand_b'):
            build,_,_,manifest=self.fixture();root=build.parent
            (root/'flavor_defines.json').write_text(json.dumps({'XB_FLAVOR_ID':brand,'XB_DEBUG':'false','XB_SENTRY_DSN':'fixture'}),encoding='utf-8')
            def audit(command, **kwargs):
                self.assertTrue(command[1].endswith('upload_sentry_symbols.py'))
                self.assertIn('--audit-only',command)
                self.assertNotIn('SENTRY_AUTH_TOKEN',kwargs['environment'])
                evidence=Path(command[command.index('--evidence')+1])
                evidence.write_text(json.dumps({'status':'audited','platform':'windows','flavor':brand}),encoding='utf-8')
            with mock.patch.object(postbuild,'resolve_cli',return_value='fixture'), \
                 mock.patch('prepare_sentry_windows_assets.check_symbol',side_effect=self.check), \
                 mock.patch.object(postbuild,'run_checked',side_effect=audit):
                self.assertEqual(postbuild.main(['--project-root',str(root),'--platform','windows','--flavor',brand,'--audit-only']),0)
            self.assertIn('FlClashHelperService',manifest.read_text())

    def test_uploader_cli_accepts_hook_siblings_but_rejects_outside_build(self):
        # Exercise the real CLI dispatch and Windows inventory audit together.
        # Only DIF parsing and the separately tested Dart companion parser are
        # replaced; a successful mocked run_checked would miss the root bug.
        for flavor, runner in [('brand_a', 'OmoFly'), ('brand_b', 'Daishu')]:
            with self.subTest(flavor=flavor):
                build, bundle, hook, manifest = self.fixture()
                (bundle/'FlClash.exe').rename(bundle/(runner+'.exe'))
                (bundle/'FlClashHelperService.exe').rename(bundle/(runner+'HelperService.exe'))
                (bundle/(runner+'.pdb')).write_bytes(b'matching')
                rows = [[runner, str(bundle/(runner+'.exe')), str(bundle/(runner+'.pdb'))]]
                for target in sorted(uploader.REQUIRED_WINDOWS_TARGETS - {'FlClash'}):
                    binary, pdb = bundle/(target+'.dll'), manifest.parent/(target+'.pdb')
                    binary.write_bytes(b'matching'); pdb.write_bytes(b'matching')
                    rows.append([target, str(binary), str(pdb)])
                manifest.write_text(''.join('\t'.join(row)+'\n' for row in rows), encoding='utf-8')
                with mock.patch('prepare_sentry_windows_assets.check_symbol', side_effect=self.check):
                    prepare_windows_assets(build, 'fixture')
                self.assertFalse(hook.resolve().is_relative_to((build/'windows').resolve()))
                report = build/'uploader-cli-evidence.json'
                arguments = ['--platform', 'windows', '--flavor', flavor, '--build-root', str(build),
                             '--evidence', str(report), '--sentry-cli', 'fixture', '--audit-only']

                def dif(cli, path, kind, **kwargs):
                    return {**self.check(cli, path, kind), 'features': 'debug', 'format': kind}

                with mock.patch.object(uploader.shutil, 'which', return_value='fixture'), \
                     mock.patch.object(uploader, 'run_cli', return_value='sentry-cli '+uploader.CLI_VERSION), \
                     mock.patch.object(uploader, 'check_symbol', side_effect=dif), \
                     mock.patch.object(uploader, 'collect_companions', return_value=([], [])), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(uploader.main(arguments), 0)
                    data = json.loads(report.read_text(encoding='utf-8'))
                    self.assertEqual(data['status'], 'audited')
                    self.assertTrue({'rust_api', 'FlClashHelperService'} <= {row['target'] for row in data['native']})
                    # The same bytes outside the actual build root remain
                    # forbidden; the fix must not disable containment checks.
                    outside = build.parent/'outside.pdb'; outside.write_bytes(b'matching')
                    text = manifest.read_text(encoding='utf-8')
                    manifest.write_text(text.replace(str(hook/'rust_api.pdb'), str(outside)), encoding='utf-8')
                    self.assertEqual(uploader.main(arguments), 1)
                    self.assertIn('escaped its build root', json.loads(report.read_text())['error'])

    @unittest.skipUnless(shutil.which('cmake') and (os.name=='nt' or shutil.which('c++')), 'CMake compiler unavailable')
    def test_cmake_owns_native_targets_but_has_no_deleted_cargokit_target(self):
        for mode in ('Release','Profile'):
            temp=tempfile.TemporaryDirectory(prefix='cmake-中文-');self.addCleanup(temp.cleanup);root=Path(temp.name)
            (root/'fixture.cpp').write_text('int main(){return 0;}\n')
            (root/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.20)
project(Fixture CXX)
set(CMAKE_BUILD_TYPE {mode})
set(CMAKE_CONFIGURATION_TYPES "Release;Profile" CACHE STRING "" FORCE)
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${{CMAKE_EXE_LINKER_FLAGS_RELEASE}}")
set(MSVC TRUE)
set(CMAKE_CXX_COMPILER_ID MSVC)
set(CMAKE_CXX_LINKER_SUPPORTS_PDB TRUE)
add_executable(FlClash fixture.cpp)
include("{HELPER.as_posix()}")
''',encoding='utf-8')
            with mock.patch.object(io,'text_encoding',side_effect=lambda encoding,*a:encoding or 'cp1252'):
                result=subprocess.run(['cmake','-S',str(root),'-B',str(root/'build')],capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            rows=(root/f'build/sentry-symbols/{mode}/targets.tsv').read_text(encoding='utf-8')
            self.assertIn('FlClash\t',rows);self.assertNotIn('rust_api\t',rows)


class HookInputSchemaTests(unittest.TestCase):
    def test_common_reader_types_for_every_platform(self):
        for platform in ('android','windows','linux','macos'):
            with tempfile.TemporaryDirectory() as folder:
                root=Path(folder);hook=root/'sentry-hook-inputs'/platform/'x64';hook.mkdir(parents=True)
                (hook/'native').write_bytes(b'runtime')
                valid={'schema_version':1,'platform':platform,'architecture':'x64','binary':'native','companions':[]}
                manifest=hook/'manifest.json';manifest.write_text(json.dumps(valid),encoding='utf-8')
                self.assertEqual(len(rust_inputs(root,platform)),1)
                for value in ([],False,{**valid,'companions':{}},{**valid,'companions':[[1]]},{**valid,'binary':None}):
                    manifest.write_text(json.dumps(value),encoding='utf-8')
                    with self.assertRaises(ValueError):rust_inputs(root,platform)
                manifest.write_bytes(b'\xff')
                with self.assertRaisesRegex(ValueError,'invalid_hook_manifest_json'):rust_inputs(root,platform)
                manifest.write_text('{broken',encoding='utf-8')
                with self.assertRaisesRegex(ValueError,'invalid_hook_manifest_json'):rust_inputs(root,platform)
                (hook/'native').unlink();(hook/'native').mkdir();manifest.write_text(json.dumps(valid),encoding='utf-8')
                with self.assertRaisesRegex(ValueError,'invalid_hook_input_type'):rust_inputs(root,platform)


if __name__=='__main__':unittest.main()
