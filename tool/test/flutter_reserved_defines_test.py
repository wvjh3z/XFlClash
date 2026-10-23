"""Actual pinned Flutter CLI argument boundary with a tiny public Dart bundle.

No client, native module or installer compilation; no symbols are uploaded.
"""
from pathlib import Path
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]

class FlutterReservedDefinesTests(unittest.TestCase):
    def test_actual_flutter_owns_build_defines_and_rejects_legacy_injection(self):
        flutter=shutil.which('flutter')
        self.assertTrue(flutter,'Formal Flutter CLI required')
        with tempfile.TemporaryDirectory(prefix='flutter-define-boundary-') as directory:
            root=Path(directory);(root/'lib').mkdir()
            (root/'pubspec.yaml').write_text('name: public_define_fixture\nversion: 1.2.3+45\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\n',encoding='utf-8')
            (root/'lib/main.dart').write_text('class Check { const Check(bool valid): assert(valid); }\n'
                'const check = Check(String.fromEnvironment("FLUTTER_BUILD_NAME") == "1.2.3" && '
                'String.fromEnvironment("FLUTTER_BUILD_NUMBER") == "46");\nvoid main() { print(check); }\n',encoding='utf-8')
            env={k:v for k,v in os.environ.items() if k not in ('FLUTTER_BUILD_NAME','FLUTTER_BUILD_NUMBER','SENTRY_AUTH_TOKEN','SENTRY_MAINTENANCE_TOKEN')}
            env['FLUTTER_SUPPRESS_ANALYTICS']='true'
            def run(args):
                return subprocess.run([flutter,*args],cwd=root,env=env,capture_output=True,text=True,
                                      encoding='utf-8',errors='replace',timeout=180)
            # The formal cold gate intentionally starts with an empty Pub cache.
            result=run(['pub','get'])
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            target={'linux':'linux-arm64' if platform.machine() in ('aarch64','arm64') else 'linux-x64',
                    'darwin':'darwin','win32':'windows-x64'}[sys.platform]
            command=['build','bundle','--debug','--no-pub','--target-platform='+target,'--build-number=46']
            for name in ('FLUTTER_BUILD_NAME','FLUTTER_BUILD_NUMBER'):
                for mode in ('direct','file'):
                    with self.subTest(name=name,mode=mode):
                        (root/'reserved.json').write_text(json.dumps({name:'legacy'}),encoding='utf-8')
                        option='--dart-define='+name+'=legacy' if mode=='direct' else '--dart-define-from-file=reserved.json'
                        result=run(command+[option])
                        self.assertNotEqual(result.returncode,0)
                        self.assertIn(name+' is used by the framework',result.stdout+result.stderr)
            result=run(command+['--dart-define=XB_FLAVOR_ID=brand_a'])
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertTrue((root/'build/flutter_assets/kernel_blob.bin').is_file())

if __name__=='__main__':unittest.main()
