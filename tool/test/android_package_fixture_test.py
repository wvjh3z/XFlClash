"""Real Package entry and brand guard with public inputs; no Dart or build."""
from pathlib import Path
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
try:
    from .android_package_fixture import prepare_android_package_fixture
    from .sentry_release_workflow_test import step_script
except ImportError:
    from android_package_fixture import prepare_android_package_fixture
    from sentry_release_workflow_test import step_script


class AndroidPackageFixtureTests(unittest.TestCase):
    def test_both_brands_formal_entry_and_incomplete_inputs(self):
        for brand in ('brand_a','brand_b'):
            for damage in (None,'module','catalog','defines','mixed_brand'):
                with self.subTest(brand=brand,damage=damage), tempfile.TemporaryDirectory(prefix='android-entry-') as tmp:
                    root=Path(tmp);prepare_android_package_fixture(root,brand)
                    binary=root/'bin';binary.mkdir();record=root/'argv.json'
                    dart=binary/'dart'
                    dart.write_text('#!'+sys.executable+'\nimport os,json,sys\nfrom pathlib import Path\nPath(os.environ["RECORDED_ARGS"]).write_text(json.dumps(sys.argv[1:]))\n',encoding='utf-8');dart.chmod(0o755)
                    python=binary/'python';python.write_text('#!/bin/sh\nexec '+shlex.quote(sys.executable)+' "$@"\n',encoding='utf-8');python.chmod(0o755)
                    if damage=='module':(root/'tool/verify_brand_identity.py').unlink()
                    if damage=='catalog':(root/'tool/identity/brands.json').unlink()
                    if damage=='defines':(root/'env.json').unlink()
                    if damage=='mixed_brand':
                        defines=json.loads((root/'env.json').read_text(encoding='utf-8'))
                        defines['XB_NATIVE_ID']='com.cloud.app.daishu' if brand=='brand_a' else 'com.cloud.app.omofly'
                        (root/'env.json').write_text(json.dumps(defines),encoding='utf-8')
                    env={k:v for k,v in os.environ.items() if not k.startswith(('PYTHONPATH','PUB_','FLUTTER_','SENTRY_'))}
                    env.update(PATH=str(binary)+os.pathsep+os.environ['PATH'],FLUTTER_ROOT=str(root),RECORDED_ARGS=str(record))
                    result=subprocess.run(['bash','-c',step_script('Package (flutter_distributor)')],cwd=root,env=env,
                                          capture_output=True,text=True,encoding='utf-8',timeout=15)
                    if damage:
                        self.assertNotEqual(result.returncode,0)
                        self.assertFalse(record.exists(),'Guard failure must stop before Dart')
                        if damage=='module':self.assertIn('verify_brand_identity',result.stderr)
                    else:
                        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                        args=json.loads(record.read_text(encoding='utf-8'))
                        self.assertEqual(args[:4],['pub','global','run','flutter_distributor:main'])
                        self.assertIn('--build-target-platform=android-arm,android-arm64',args)
                        self.assertEqual(args[-2:],['--build-flavor',brand])


if __name__=='__main__':unittest.main()
