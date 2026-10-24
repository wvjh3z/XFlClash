import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from tool.test.webkit_probe_support import owned, wait_ready, wait_complete, ProbeFailure


class ReadinessTests(unittest.TestCase):
    def test_controlled_clock_waits_for_ready_not_fixed_sleep(self):
        class Process:
            returncode=None
            def poll(self): return None
        ticks=[0.0]
        def sleep(value): ticks[0]+=value
        self.assertEqual(wait_ready(Process(),lambda:'23' if ticks[0]>=.1 else '',
                                    phase='xvfb',timeout=1,clock=lambda:ticks[0],sleep=sleep),'23')
        with self.assertRaisesRegex(ProbeFailure,'readiness timeout'):
            wait_ready(Process(),lambda:'',phase='xvfb',timeout=.1,clock=lambda:ticks[0],sleep=sleep)

    def test_formal_linux_job_provisions_the_session_bus(self):
        import shlex
        root=Path(__file__).resolve().parents[2]
        workflow=(root/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        installs=[shlex.split(line.strip()) for line in workflow.splitlines()
                  if line.strip().startswith('sudo apt-get install ')]
        self.assertTrue(any('xvfb' in args and 'dbus-daemon' in args for args in installs))

    def test_exit_is_not_mistaken_for_readiness(self):
        class Process:
            returncode=7
            def poll(self):return 7
        with self.assertRaisesRegex(ProbeFailure,'exit=7'):
            wait_ready(Process(),lambda:'23',phase='xvfb',timeout=1)


@unittest.skipUnless(os.name=='posix','POSIX process groups')
class CleanupTests(unittest.TestCase):
    def test_success_and_failure_cleanup_owned_descendant_with_logs(self):
        for fail in (False,True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);pidfile=root/'child.pid'
                code=('import subprocess,sys,time; from pathlib import Path; '
                      'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(120)"]); '
                      'Path(sys.argv[1]).write_text(str(p.pid)); '
                      'print("PHASE=webkit_context",flush=True); time.sleep(120)')
                def run():
                    with owned([sys.executable,'-c',code,str(pidfile)],root,'probe') as (p,out,err):
                        wait_ready(p,lambda:pidfile.exists() and 'PHASE=webkit_context' in out.read_text(),phase='child',timeout=10)
                        if fail:wait_complete(p,out,timeout=.1)
                if fail:
                    with self.assertRaisesRegex(ProbeFailure,'PHASE=webkit_context'):run()
                else:run()
                pid=int(pidfile.read_text())
                # Reaped by init or zombie awaiting init: neither is running.
                stat=Path(f'/proc/{pid}/stat')
                if stat.exists():self.assertEqual(stat.read_text().split(') ')[1][0],'Z')

    def test_exit_code_and_completion_are_both_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for code,message,pattern in [(7,'PHASE=complete','exit=7'),(0,'PHASE=gtk_init','without completion'),(0,'PHASE=complete',None)]:
                def run():
                    with owned([sys.executable,'-c',f'print({message!r}); raise SystemExit({code})'],root,'probe') as (p,out,err):
                        return wait_complete(p,out,timeout=10)
                if pattern:
                    with self.assertRaisesRegex(ProbeFailure,pattern):run()
                else:self.assertEqual(run().strip(),'PHASE=complete')

    def test_cleanup_failure_cannot_be_reported_as_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            def cleanup(process,diagnostic):
                process.wait(timeout=10);return False
            with patch('tool.test.webkit_probe_support.stop_tree',side_effect=cleanup):
                with self.assertRaisesRegex(ProbeFailure,'cleanup failed'):
                    with owned([sys.executable,'-c','pass'],Path(tmp),'probe'):pass

if __name__=='__main__':unittest.main()
