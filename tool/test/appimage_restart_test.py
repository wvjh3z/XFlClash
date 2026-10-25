"""Execute the shipped restart script with harmless processes; no app builds."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[2]
SCRIPT=re.search(r"const xbAppImageRestartScript = r'''(.*?)''';",(ROOT/'lib/xboard/services/xb_appimage_restart.dart').read_text(),re.S)[1]

@unittest.skipUnless(sys.platform=='linux','Linux proc identity')
class AppImageRestartTests(unittest.TestCase):
    def test_brand_paths_wait_for_exact_old_process(self):
        for brand in ('OmoFly','袋鼠加速'):
            with self.subTest(brand=brand), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp); marker=root/'launched'; control=root/'control';control.mkdir();ready=control/'ready'
                target=root/(brand+" ' app.AppImage")
                target.write_text('#!/bin/sh\nprintf launched > "'+str(marker)+'"\n');target.chmod(0o700)
                parent=subprocess.Popen([sys.executable,'-c','import sys; sys.stdin.read()'],stdin=subprocess.PIPE)
                waiter=None
                try:
                    stat=Path(f'/proc/{parent.pid}/stat').read_text().rsplit(') ',1)[1].split()[19]
                    waiter=subprocess.Popen(['/bin/sh','-c',SCRIPT,'fixture',str(parent.pid),stat,str(target),str(ready)])
                    deadline=time.monotonic()+10
                    while not ready.exists():
                        self.assertIsNone(waiter.poll())
                        self.assertLess(time.monotonic(),deadline)
                        time.sleep(.01)
                    self.assertFalse(marker.exists())
                    (control/'commit').write_text('commit')
                    parent.communicate(timeout=10)
                    self.assertEqual(waiter.wait(timeout=10),0)
                    self.assertEqual(marker.read_text(),'launched')
                finally:
                    if parent.poll() is None:parent.kill();parent.wait()
                    if waiter is not None and waiter.poll() is None:waiter.kill();waiter.wait()

    def test_live_parent_timeout_never_launches_or_kills_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);control=root/'control';control.mkdir();(control/'commit').write_text('commit');sleep=root/'sleep';sleep.write_text('#!/bin/sh\nexit 0\n');sleep.chmod(0o700);(root/'rm').symlink_to('/bin/rm')
            marker=root/'bad';target=root/'target';target.write_text('#!/bin/sh\ntouch "'+str(marker)+'"\n');target.chmod(0o700)
            pid=os.getpid();start=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[19]
            r=subprocess.run(['/bin/sh','-c',SCRIPT,'fixture',str(pid),start,str(target),str(control/'ready')],env={**os.environ,'PATH':str(root)},timeout=10)
            self.assertEqual(r.returncode,124);self.assertFalse(marker.exists())
            os.kill(pid,0)

    def test_cancelled_waiter_never_launches_even_after_commit(self):
        for committed in (False, True):
            with self.subTest(committed=committed), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);control=root/'control';control.mkdir();marker=root/'launched'
                target=root/'target';target.write_text('#!/bin/sh\nprintf launched > "'+str(marker)+'"\n');target.chmod(0o700)
                pid=os.getpid();start=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[19]
                waiter=subprocess.Popen(['/bin/sh','-c',SCRIPT,'fixture',str(pid),start,str(target),str(control/'ready')])
                try:
                    deadline=time.monotonic()+10
                    while not (control/'ready').exists():
                        self.assertIsNone(waiter.poll());self.assertLess(time.monotonic(),deadline);time.sleep(.01)
                    if committed:(control/'commit').write_text('commit')
                    shutil.rmtree(control)
                    self.assertEqual(waiter.wait(timeout=10),125)
                    self.assertFalse(marker.exists());os.kill(pid,0)
                finally:
                    if waiter.poll() is None:waiter.kill();waiter.wait()

    def test_missing_host_tools_fail_before_readiness(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);control=root/'control';control.mkdir();ready=control/'ready'
            pid=os.getpid();start=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[19]
            result=subprocess.run(['/bin/sh','-c',SCRIPT,'fixture',str(pid),start,'/bin/true',str(ready)],
                                  env={**os.environ,'PATH':str(root/'missing')},capture_output=True,timeout=10)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(ready.exists())
            self.assertFalse((control/'accepted').exists())

    def test_pid_reuse_does_not_wait_for_unrelated_instance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);control=root/'control';control.mkdir();(control/'commit').write_text('commit')
            r=subprocess.run(['/bin/sh','-c',SCRIPT,'fixture',str(os.getpid()),'0','/bin/true',str(control/'ready')],timeout=10)
            self.assertEqual(r.returncode,0)

if __name__=='__main__':unittest.main()
