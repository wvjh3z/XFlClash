"""Only harmless process fixtures; never runs Flutter or native compilation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import build_diagnostics as diagnostic
ROOT=Path(__file__).resolve().parents[2]

class FinalizationTests(unittest.TestCase):
    def test_failures_do_not_replace_main_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for code in (0,7,130,143):
                with mock.patch.object(diagnostic,'collect',side_effect=OSError('fixture')):
                    self.assertEqual(diagnostic.finalize(root,root/'reports',code),code)
                result=json.loads((root/'reports/finalization.json').read_text(encoding='utf-8'))
                self.assertEqual(result['main_exit_code'],code)
                self.assertFalse(result['diagnostics_complete'])
                with mock.patch.object(diagnostic,'write_report',side_effect=OSError('fixture')):
                    self.assertEqual(diagnostic.finalize(root,root/'reports',code),code)

    def test_cli_session_path_is_utf8_lf_for_shell_consumers(self):
        with tempfile.TemporaryDirectory(prefix='诊断 path-') as tmp:
            result=subprocess.run([sys.executable,str(ROOT/'tool/build_diagnostics.py'),'--root',tmp,'--create-session'],env={**os.environ,'PYTHONUTF8':'0','PYTHONIOENCODING':'cp1252'},capture_output=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn(b'\r',result.stdout)
            self.assertTrue(Path(result.stdout.decode('utf-8').strip()).is_dir())

    @unittest.skipUnless(shutil.which('bash'), 'Bash required')
    def test_real_desktop_entry_retains_reports_and_original_exit(self):
        with tempfile.TemporaryDirectory(prefix='desktop-report-中文 space-') as tmp:
            root=Path(tmp)
            for name in ('scripts/package_desktop_local.sh','scripts/local_build_diagnostics.sh','tool/build_diagnostics.py','tool/native_hook_diagnostics.py','tool/pub_get_retry.py','tool/owned_process_cleanup.py'):
                target=root/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,target)
            flavor=root/"flavors/brand_a/flavor.yaml"
            flavor.parent.mkdir(parents=True,exist_ok=True)
            flavor.write_text("appName: Fixture\n",encoding="utf-8")
            # The actual entry runs through prerequisites, native preparation,
            # clean and finalization; platform/build commands are harmless stubs.
            script=r'''
set -e
uname() { if [ "$1" = -s ]; then printf Darwin; else printf x86_64; fi; }
flutter() { if [ "$1" = clean ]; then rm -rf build; return "$TEST_EXIT"; fi; return 9; }
dart() { :; }
git() { :; }
appdmg() { :; }
python3() {
 if [ "$1" = tool/prepare_native_build.py ]; then
  "$TEST_PYTHON" -c 'import os,json;from pathlib import Path;p=Path(os.environ["XFLCLASH_DIAGNOSTICS_DIR"])/"dependency-retries/go.json";p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps({"passed":True}),encoding="utf-8")'
 else
  "$TEST_PYTHON" "$@"
 fi
}
export -f uname flutter dart git appdmg python3
bash scripts/package_desktop_local.sh brand_a macos-amd64 --build-number=26
'''
            for code in (7,143):
                env={**os.environ,'TEST_PYTHON':sys.executable,'TEST_EXIT':str(code)}
                p=subprocess.run(['bash','-c',script],cwd=root,env=env,capture_output=True,timeout=30)
                self.assertEqual(p.returncode,code,p.stdout+p.stderr)
                sessions=sorted((root/'.local-build/desktop-diagnostics').glob('run-*'),key=lambda p:p.stat().st_mtime_ns)
                current=sessions[-1]
                self.assertTrue((current/'dependency-retries/go.json').exists())
                value=json.loads((current/'finalization.json').read_text(encoding='utf-8'))
                self.assertEqual(value['main_exit_code'],code)
            # Exercise normal success and a real TERM signal through the same
            # production EXIT handler, without any build command.
            terminal_script = r'''set -e
python3() { "$TEST_PYTHON" "$@"; }
REPO_DIR="$TEST_ROOT"
source "$REPO_DIR/scripts/local_build_diagnostics.sh"
if [ "$TEST_EXIT" = 143 ]; then kill -TERM $$; fi
exit 0
'''
            for code in (0,143):
                p=subprocess.run(['bash','-c',terminal_script],cwd=root,env={**os.environ,'TEST_PYTHON':sys.executable,'TEST_ROOT':root.as_posix(),'TEST_EXIT':str(code)},capture_output=True,timeout=30)
                self.assertEqual(p.returncode,code,p.stdout+p.stderr)
                latest=max((root/'.local-build/desktop-diagnostics').glob('run-*'),key=lambda p:p.stat().st_mtime_ns)
                self.assertEqual(json.loads((latest/'finalization.json').read_text(encoding='utf-8'))['main_exit_code'],code)
            # Regression control: fail the collector itself; retain main status.
            (root/'tool/build_diagnostics.py').write_text('import sys\nif "--create-session" in sys.argv: print("'+root.as_posix()+'/failed-finalizer")\nelse: sys.exit(99)\n',encoding='utf-8')
            p=subprocess.run(['bash','-c',script],cwd=root,env={**os.environ,'TEST_PYTHON':sys.executable,'TEST_EXIT':'7'},capture_output=True,timeout=30)
            self.assertEqual(p.returncode,7)

if __name__=='__main__':unittest.main()
