"""Pinned NDK selection and target gating; never cross-compile from these tests."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tool'))
import android_ndk_environment as ndk

class NdkEnvironmentTests(unittest.TestCase):
    def test_explicit_pin_and_export(self):
        with tempfile.TemporaryDirectory(prefix='ndk 中文 ') as directory:
            root=Path(directory)/'ndk';(root/'toolchains/llvm/prebuilt').mkdir(parents=True)
            (root/'source.properties').write_text('Pkg.Revision = '+ndk.PIN+'\n', encoding='utf-8')
            output=Path(directory)/'github-env'
            result=subprocess.run([sys.executable, str(ROOT/'tool/android_ndk_environment.py'), '--path', str(root), '--github-env'],
                env={**os.environ,'GITHUB_ENV':str(output)}, capture_output=True, text=True, encoding='utf-8', timeout=20)
            self.assertEqual(result.returncode,0,result.stderr)
            lines=output.read_text(encoding='utf-8').splitlines()
            self.assertEqual(lines,[f'{key}={root.resolve()}' for key in ('ANDROID_NDK','ANDROID_NDK_HOME','ANDROID_NDK_ROOT')])
            (root/'source.properties').write_text('Pkg.Revision = 27.3.13750724\n',encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'version differs'):ndk.validate_ndk(str(root))
            for value in ('',' ','x\ny'):
                with self.subTest(value=value),self.assertRaises(ValueError):ndk.validate_ndk(value)

    def test_linux_skips_android_even_with_preinstalled_ndk_and_android_fails_if_missing(self):
        for target,passed in [('linux',True),('android',False)]:
            env={**os.environ,'XFLCLASH_TEST_PLATFORM':target}
            env.pop('ANDROID_NDK',None)
            if target=='linux':env['ANDROID_NDK']='/preinstalled/old/ndk'
            result=subprocess.run([sys.executable,str(ROOT/'tool/test/native_release_migration_test.py'),'AndroidRustBuildIdTests'],
                env=env,capture_output=True,text=True,encoding='utf-8',timeout=30)
            self.assertEqual(result.returncode==0,passed,result.stderr)
            if passed:self.assertIn('skipped=1',result.stderr)
            else:
                self.assertIn('Explicit Android NDK path is required',result.stderr)
                self.assertNotIn('skipped=',result.stderr)

    def test_workflow_binds_action_output_before_targeted_checks(self):
        text=(ROOT/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        self.assertIn('SELECTED_NDK: ${{ steps.android_ndk.outputs.ndk-path }}',text)
        self.assertIn('XFLCLASH_TEST_PLATFORM: ${{ matrix.platform }}',text)
        self.assertLess(text.index('- name: Setup NDK'),text.index('- name: Bind pinned NDK'))
        self.assertLess(text.index('- name: Bind pinned NDK'),text.index('- name: Check build tool encoding'))

if __name__=='__main__':unittest.main()
