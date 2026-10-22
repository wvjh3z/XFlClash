#!/usr/bin/env python3
"""CMake declarations plus Native Assets handoff; no Windows client compilation."""
import io
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

HELPER = Path(__file__).resolve().parents[2] / 'windows/xboard_sentry_symbols.cmake'


class RustManifestTests(unittest.TestCase):
    def fixture(self):
        temp=tempfile.TemporaryDirectory(prefix='sentry-rust-中文-');self.addCleanup(temp.cleanup)
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

    def test_real_postbuild_handoff_is_idempotent_and_copies_helper(self):
        build,bundle,hook,manifest=self.fixture()
        with mock.patch('prepare_sentry_windows_assets.check_symbol',side_effect=self.check):
            prepare_windows_assets(build,'fixture-cli');first=manifest.read_bytes()
            prepare_windows_assets(build,'fixture-cli')
        self.assertEqual(first,manifest.read_bytes())
        rows=[row.split('\t') for row in first.decode().splitlines()]
        self.assertEqual({r[0] for r in rows},{'FlClash','rust_api','FlClashHelperService'})
        self.assertTrue(all(Path(row[2]).is_relative_to(build) for row in rows))
        self.assertEqual((build/'sentry-hook-inputs/windows/helper/helper.pdb').read_bytes(),b'matching')

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


if __name__=='__main__':unittest.main()
