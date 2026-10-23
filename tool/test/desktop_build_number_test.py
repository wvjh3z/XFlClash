"""Run the real local shell entry through argument validation, without building."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]

@unittest.skipUnless(os.name=='posix' and shutil.which('bash'),'POSIX shell required')
class DesktopNumberTests(unittest.TestCase):
    def test_required_explicit_number_and_both_brands(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'scripts').mkdir()
            script=root/'scripts/package_desktop_local.sh'
            shutil.copyfile(ROOT/'scripts/package_desktop_local.sh',script)
            for brand in ('brand_a','brand_b'):
                (root/f'flavors/{brand}').mkdir(parents=True)
                (root/f'flavors/{brand}/flavor.yaml').write_text('appName: Fixture\n',encoding='utf-8')
                for args in ([],['--build-number=0'],['--build-number=01'],['--build-number=65536'],
                             ['--build-number=99999999999999999999999999'],['--build-number=abc'],
                             ['--build-number=1','--build-number=2'],['--build-number=','--build-number=2']):
                    result=subprocess.run(['bash',str(script),brand,*args],capture_output=True,text=True,encoding='utf-8',timeout=10)
                    self.assertEqual(result.returncode,2,result.stdout+result.stderr)
                    self.assertIn('--build-number',result.stdout)
                # A valid number reaches the existing host/platform guard;
                # deliberately choose a different OS to prohibit all build steps.
                target='windows-amd64' if os.uname().sysname=='Linux' else 'linux-amd64'
                for number in ('1','26','65535'):
                    result=subprocess.run(['bash',str(script),brand,target,'--build-number='+number],capture_output=True,text=True,encoding='utf-8',timeout=10)
                    self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                    self.assertIn('桌面包不能交叉编译',result.stdout)
            self.assertFalse((root/'.local-build').exists())
            self.assertEqual(list((root/'scripts').iterdir()),[script])

if __name__=='__main__':unittest.main()
