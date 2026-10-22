#!/usr/bin/env python3
"""Native Assets handoff/fixture checks; never compile the Flutter application."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tool'))
import flutter_check
import prepare_native_build as native
from sentry_hook_inputs import rust_inputs
from sentry_elf import inspect_elf
from prepare_sentry_native_symbols import Preparer, PreparationError


class NativeInputTests(unittest.TestCase):
    def test_ca_atomic_verification_and_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);output=root/'core/Clash.Meta/component/ca/ca-certificates.crt';output.parent.mkdir(parents=True)
            output.write_bytes(b'previous')
            data=b'-----BEGIN CERTIFICATE-----\ncontrolled-fixture\n'
            pins={**native.PINS,'ca_sha256':hashlib.sha256(data).hexdigest()}
            def download(path,*args):path.write_bytes(data)
            with mock.patch.object(native,'PINS',pins):
                native.prepare_ca(root,downloader=download);self.assertEqual(output.read_bytes(),data)
                native.prepare_ca(root,downloader=lambda *args:self.fail('valid cache should not download'))
                output.write_bytes(b'previous')
                with self.assertRaisesRegex(RuntimeError,'checksum'):
                    native.prepare_ca(root,downloader=lambda path,*args:path.write_bytes(b'wrong'))
                self.assertEqual(output.read_bytes(),b'previous')

    def test_requested_platform_targets_not_all_toolchains(self):
        self.assertEqual(native.targets('windows','amd64'),['x86_64-pc-windows-msvc'])
        self.assertEqual(native.targets('macos','arm64'),['aarch64-apple-darwin'])
        self.assertEqual(native.targets('linux','x86_64'),['x86_64-unknown-linux-gnu'])
        self.assertEqual(set(native.targets('android','amd64')),{'armv7-linux-androideabi','aarch64-linux-android','x86_64-linux-android'})
        with self.assertRaises(RuntimeError):native.targets('linux','unknown')

    def test_unit_check_restores_lf_and_crlf_even_on_failure(self):
        for eol in ('\n','\r\n'):
            with tempfile.TemporaryDirectory() as folder:
                path=Path(folder)/'pubspec.yaml'
                original='hooks:\n  user_defines:\n    setup:\n      build_assets: true\n    rust_api:\n      build_assets: true\n'.replace('\n',eol).encode()
                path.write_bytes(original)
                with self.assertRaisesRegex(ValueError,'controlled'):
                    with flutter_check.without_native_builds(path):
                        self.assertEqual(path.read_bytes().count(b'build_assets: false'),2)
                        raise ValueError('controlled')
                self.assertEqual(path.read_bytes(),original)

    def test_hook_paths_cannot_escape_or_hide_missing_companions(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);hook=root/'sentry-hook-inputs/windows/x64';hook.mkdir(parents=True)
            record={'schema_version':1,'platform':'windows','architecture':'x64','binary':'rust_api.dll','companions':['rust_api.pdb']}
            manifest=hook/'manifest.json';manifest.write_text(json.dumps(record))
            with self.assertRaises(ValueError):rust_inputs(root,'windows')
            (hook/'rust_api.dll').write_bytes(b'runtime');(hook/'rust_api.pdb').write_bytes(b'debug')
            self.assertEqual(len(rust_inputs(root,'windows')),1)
            record['binary']='../../escape.dll';manifest.write_text(json.dumps(record))
            with self.assertRaises(ValueError):rust_inputs(root,'windows')

    def test_macos_renderer_tracks_architecture_and_retains_plist_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/'macos/Runner/Info.plist';path.parent.mkdir(parents=True)
            value={'CFBundleDisplayName':'袋鼠加速','CFBundleURLTypes':[{'CFBundleURLSchemes':['flclash']}]}
            path.write_bytes(plistlib.dumps(value))
            native.prepare_macos_renderer(root,'amd64')
            self.assertEqual(plistlib.loads(path.read_bytes()),{**value,'FLTEnableImpeller':False})
            native.prepare_macos_renderer(root,'arm64')
            self.assertEqual(plistlib.loads(path.read_bytes()),value)

    def test_arm_flutter_source_ref_and_macos_pods_follow_pinned_baseline(self):
        text=(ROOT/'.github/workflows/release-package.yml').read_text()
        self.assertIn(native.PINS['flutter_revision'],text)
        self.assertIn("matrix.platform == 'linux' && matrix.arch == 'arm64' && 'master' || 'stable'",text)
        self.assertIn("platform :osx, '12.0'",(ROOT/'macos/Podfile').read_text())
        for mode in ('Debug','Release'):
            self.assertIn(f'Pods-Runner.{mode.lower()}.xcconfig',(ROOT/f'macos/Flutter/Flutter-{mode}.xcconfig').read_text())

    def test_installer_has_one_event_and_preserves_upstream_cleanup_order(self):
        template=(ROOT/'windows/packaging/exe/inno_setup.iss').read_text()
        include=(ROOT/'windows/packaging/exe/vc_runtime.iss').read_text()
        self.assertEqual((template+include).count('function PrepareToInstall('),1)
        entry=template.split('function PrepareToInstall(',1)[1].split('procedure CurStepChanged',1)[0]
        self.assertLess(entry.index('XbPrepareVCRuntime'),entry.index('UnregisterHelperService'))
        self.assertLess(entry.index('if Result <>'),entry.index('KillProcesses'))
        self.assertIn('CurUninstallStepChanged',template)

    def test_real_hook_regression_is_on_formal_path_after_dependencies(self):
        workflow=(ROOT/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        step=workflow.index('python tool/test/native_hook_environment_test.py')
        self.assertLess(workflow.index('- name: Check setup build hooks'),step)
        self.assertLess(workflow.index('- name: Prepare native build inputs'),step)
        self.assertLess(step,workflow.index('- name: Package (flutter_distributor)'))

    def test_formal_entries_have_no_deleted_native_build_commands(self):
        for name in ('.github/workflows/release-package.yml','scripts/package_desktop_local.sh','tool/build_android_local.py'):
            text=(ROOT/name).read_text(encoding='utf-8')
            self.assertNotIn('plugins/setup/buildkit',text)
            self.assertIn('prepare_native_build.py',text)
        profiles=[tomllib.loads((ROOT/path).read_text())['profile']['release'] for path in ('plugins/rust_api/rust/Cargo.toml','services/helper/Cargo.toml')]
        for profile in profiles:
            self.assertEqual(profile['debug'],2);self.assertFalse(profile['strip'])
            self.assertNotEqual(profile.get('split-debuginfo'),'packed', 'Linux must retain DWARF in ELF, not external DWP')


@unittest.skipUnless(sys.platform=='linux' and shutil.which('cargo') and shutil.which('objcopy'), 'Linux Rust/ELF fixture tools required')
class RealRustProfileTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('ANDROID_NDK') and os.environ.get('FLUTTER_ROOT'), 'Android NDK and Flutter graph required')
    def test_android_rust_actual_ndk_build_ids_match_stripped_runtime_and_debug(self):
        with tempfile.TemporaryDirectory(prefix='android-rust-id-') as folder:
            root=Path(folder);crate=root/'crate';(crate/'src').mkdir(parents=True)
            probe=root/'environment.dart'
            probe.write_text("import 'dart:convert';\nimport 'package:code_assets/code_assets.dart';\n"
                +f"import '{(ROOT/'plugins/rust_api/hook/xboard_symbols.dart').as_uri()}';\n"
                +'void main() { print(jsonEncode({for(final os in [OS.android,OS.linux,OS.windows,OS.macOS]) os.name:xboardRustSymbolEnvironment(os)})); }\n')
            result=subprocess.run([str(Path(os.environ['FLUTTER_ROOT'])/'bin/cache/dart-sdk/bin/dart'),
                '--packages='+str(ROOT/'.dart_tool/package_config.json'),str(probe)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            environments=json.loads(result.stdout)
            self.assertEqual(environments['linux'],{});self.assertEqual(environments['windows'],{})
            self.assertEqual(environments['macos'],{'CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO':'packed'})
            profile=(ROOT/'plugins/rust_api/rust/Cargo.toml').read_text().split('[profile.release]',1)[1].split('[profile.dev]',1)[0]
            (crate/'Cargo.toml').write_text('[package]\nname="fixture"\nversion="0.0.1"\nedition="2021"\n[lib]\ncrate-type=["cdylib"]\n[profile.release]\n'+profile)
            (crate/'src/lib.rs').write_text('#[no_mangle]\npub extern "C" fn native_fixture(x:i32)->i32 {x+42}\n')
            ndk=next((Path(os.environ['ANDROID_NDK'])/'toolchains/llvm/prebuilt').glob('*/bin'))
            for target,clang,abi in [('aarch64-linux-android','aarch64-linux-android','arm64-v8a'),
                                     ('armv7-linux-androideabi','armv7a-linux-androideabi','armeabi-v7a'),
                                     ('x86_64-linux-android','x86_64-linux-android','x86_64')]:
                with self.subTest(abi=abi):
                    env={k:v for k,v in os.environ.items() if k not in ('RUSTFLAGS','CARGO_ENCODED_RUSTFLAGS')}
                    env['CARGO_TARGET_'+target.replace('-','_').upper()+'_LINKER']=str(ndk/(clang+'35-clang'))
                    command=['cargo','build','--release','--offline','--target',target]
                    result=subprocess.run(command,cwd=crate,env=env,capture_output=True,text=True,timeout=120)
                    self.assertEqual(result.returncode,0,result.stderr)
                    binary=crate/f'target/{target}/release/libfixture.so'
                    self.assertFalse(inspect_elf(binary)['build_id'], 'negative control must reproduce NDK default without Build ID')
                    result=subprocess.run(command,cwd=crate,env={**env,**environments['android']},capture_output=True,text=True,timeout=120)
                    self.assertEqual(result.returncode,0,result.stderr)
                    original=inspect_elf(binary);self.assertTrue(original['build_id'])
                    build=root/abi/'build';runtime=build/'runtime/librust_api.so';runtime.parent.mkdir(parents=True)
                    shutil.copyfile(binary,runtime)
                    subprocess.run([str(ndk/'llvm-objcopy'),'--strip-debug',str(runtime)],check=True)
                    preparer=Preparer(build,'android',str(ndk/'llvm-objcopy'))
                    preparer.add('librust_api.so',abi,runtime,[binary],'rust',True)
                    debug=build/preparer.artifacts[0]['debug_file']
                    self.assertEqual(inspect_elf(runtime)['build_id'],original['build_id'])
                    self.assertEqual(inspect_elf(debug)['build_id'],original['build_id'])
                    self.assertFalse(inspect_elf(debug)['has_executable_text'])

    def test_release_profile_retains_line_info_for_native_assets_and_matching_debug_only(self):
        with tempfile.TemporaryDirectory(prefix='rust-symbol-') as folder:
            root=Path(folder);crate=root/'crate';(crate/'src').mkdir(parents=True)
            profile=(ROOT/'plugins/rust_api/rust/Cargo.toml').read_text().split('[profile.release]',1)[1].split('[profile.dev]',1)[0]
            (crate/'Cargo.toml').write_text('[package]\nname="fixture"\nversion="0.0.1"\nedition="2021"\n[lib]\ncrate-type=["cdylib"]\n[profile.release]\n'+profile)
            (crate/'src/lib.rs').write_text('#[no_mangle]\npub extern "C" fn native_fixture(x:i32)->i32 {x+42}\n')
            result=subprocess.run(['cargo','build','--release','--offline'],cwd=crate,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=120)
            self.assertEqual(result.returncode,0,result.stderr)
            binary=crate/'target/release/libfixture.so';info=inspect_elf(binary)
            self.assertTrue(info['has_debug_info'] and info['has_debug_line']);self.assertTrue(info['build_id'])
            arch={'x86_64':'x64','aarch64':'arm64'}[info['architecture']]
            build=root/'build';runtime=build/'runtime/librust_api.so';runtime.parent.mkdir(parents=True);shutil.copyfile(binary,runtime)
            subprocess.run(['objcopy','--strip-debug',str(runtime)],check=True)
            preparer=Preparer(build,'linux','objcopy');preparer.add('librust_api.so',arch,runtime,[binary],'rust',True)
            report=json.loads(preparer.finish().read_text());debug=inspect_elf(build/report['artifacts'][0]['debug_file'])
            self.assertFalse(debug['has_executable_text']);self.assertTrue(debug['has_debug_info']);self.assertEqual(debug['build_id'],info['build_id'])
            from upload_sentry_symbols import check_symbol
            cli=os.environ.get('SENTRY_CLI') or shutil.which('sentry-cli')
            self.assertTrue(cli, 'The real Sentry CLI is required for the native symbol fixture')
            full=check_symbol(cli,binary,'elf')
            companion=check_symbol(cli,build/report['artifacts'][0]['debug_file'],'elf')
            self.assertEqual(full['debug_ids'],companion['debug_ids'])
            with self.assertRaises(PreparationError):
                Preparer(build,'linux','objcopy').add('librust_api.so',arch,runtime,[runtime],'rust',True)


if __name__=='__main__':unittest.main()
