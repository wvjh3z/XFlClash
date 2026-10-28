"""Offline Go dependency preparation and bounded real subprocess controls."""
import json
import os
import signal
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_go_dependencies as go
import pub_get_retry as retry


class GoPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('go.mod','go.sum','Clash.Meta/go.mod','Clash.Meta/go.sum'):
            p=self.root/'core'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture',encoding='utf-8')
        self.report=self.root/'build/dependency-retries/go.json'
        inspector=mock.patch.object(go,'validate_replacements')
        inspector.start();self.addCleanup(inspector.stop)

    def prepare(self, output, failures, *, mutate=False):
        count=self.root/'count'
        script=self.root/'go-fixture.py'
        script.write_text('import sys\nfrom pathlib import Path\np=Path('+repr(str(count))+')\nn=int(p.read_text(encoding="utf-8"))+1 if p.exists() else 1\np.write_text(str(n))\nprint('+repr(output)+')\nsys.exit(1 if n<='+str(failures)+' else 0)\n',encoding='utf-8')
        def runner(command,cwd,env,**options):
            self.assertEqual(command[1:],['mod','download'])
            self.assertNotEqual(cwd,self.root/'core')
            self.assertFalse(cwd.resolve().is_relative_to(self.root.resolve()))
            self.assertEqual(env['GOWORK'],'off')
            self.assertEqual(env['GOTOOLCHAIN'],'local')
            if mutate:(cwd/'go.sum').write_text('changed',encoding='utf-8')
            return retry.execute([sys.executable,str(script)],cwd,env,**{**options,'delays':(0,0),'emit':lambda _:None})
        with mock.patch.object(go.shutil,'which',return_value=sys.executable):
            go.prepare(self.root,runner=runner)

    def test_http2_then_success_and_old_report_recovery(self):
        with self.assertRaises(RuntimeError):self.prepare('unexpected deterministic error',10)
        self.assertFalse(json.loads(self.report.read_text(encoding='utf-8'))['passed'])
        (self.root/'count').unlink()
        self.prepare('stream error: stream ID 181; INTERNAL_ERROR; received from peer',1)
        report=json.loads(self.report.read_text(encoding='utf-8'))
        self.assertTrue(report['passed']);self.assertEqual(len(report['retry']['attempts']),2)

    def test_exhaustion_and_checksum_are_not_success(self):
        for message,attempts in [('stream error: stream ID 181; INTERNAL_ERROR; received from peer',3),('connection reset\nSECURITY ERROR checksum mismatch',1),('unknown revision',1)]:
            with self.subTest(message=message):
                (self.root/'count').unlink(missing_ok=True)
                with self.assertRaises(RuntimeError):self.prepare(message,10)
                report=json.loads(self.report.read_text(encoding='utf-8'));self.assertFalse(report['passed'])
                self.assertEqual(len(report['retry']['attempts']),attempts)

    def test_isolated_writes_preserve_sources_on_success_and_failure(self):
        before=go.snapshot(self.root/'core')
        for failures in (0,10):
            (self.root/'count').unlink(missing_ok=True)
            if failures:
                with self.assertRaises(RuntimeError):self.prepare('deterministic failure',failures,mutate=True)
            else:self.prepare('',0,mutate=True)
            self.assertEqual(go.snapshot(self.root/'core'),before)
            report=json.loads(self.report.read_text(encoding='utf-8'))
            self.assertEqual(report['isolated_changed_inputs'],['go.sum'])
            self.assertEqual(report['changed_inputs'],[])


    def test_isolated_manifest_change_is_still_an_error(self):
        before=go.snapshot(self.root/'core')
        def runner(command,cwd,env,**options):
            (cwd/'go.mod').write_text('changed requirements',encoding='utf-8')
            return 0,{'outcome':'success'}
        with mock.patch.object(go.shutil,'which',return_value=sys.executable),self.assertRaisesRegex(RuntimeError,'isolated_manifest_changed'):
            go.prepare(self.root,runner=runner)
        self.assertEqual(go.snapshot(self.root/'core'),before)

    def test_missing_tool_overwrites_old_success(self):
        self.prepare('',0)
        with mock.patch.object(go.shutil,'which',return_value=None),self.assertRaises(RuntimeError):go.prepare(self.root)
        self.assertFalse(json.loads(self.report.read_text(encoding='utf-8'))['passed'])

    def test_cancellation_reaches_runner_and_handlers_are_restored(self):
        before=go.snapshot(self.root/'core')
        previous=signal.getsignal(signal.SIGTERM)
        def runner(command,cwd,env,**options):
            (cwd/'go.mod').write_text('cancelled isolated write',encoding='utf-8')
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM,None)
            self.assertEqual(options['cancelled'](),signal.SIGTERM)
            return 143,{'outcome':'cancelled','attempts':[]}
        with mock.patch.object(go.shutil,'which',return_value=sys.executable),self.assertRaises(SystemExit) as raised:
            go.prepare(self.root,runner=runner)
        self.assertEqual(raised.exception.code,143)
        self.assertEqual(go.snapshot(self.root/'core'),before)
        self.assertIs(signal.getsignal(signal.SIGTERM),previous)
        self.assertFalse(json.loads(self.report.read_text(encoding='utf-8'))['passed'])

    def test_redirecting_environment_is_neutralized(self):
        def runner(command,cwd,env,**options):
            self.assertEqual(env['GOFLAGS'],'')
            self.assertEqual(env['GOENV'],'off')
            return 0,{'outcome':'success'}
        with mock.patch.object(go.shutil,'which',return_value=sys.executable):
            go.prepare(self.root,runner=runner,environment={'PATH':os.environ.get('PATH',''),'GOFLAGS':'-modfile=outside.mod','GOENV':'outside.env'})
            with self.assertRaisesRegex(RuntimeError,'outside the source checkout'):
                go.prepare(self.root,runner=runner,environment={'PATH':'','GOMODCACHE':str(self.root/'core')})

    def test_late_cancel_during_cleanup_or_success_report(self):
        real_temp=go.tempfile.TemporaryDirectory
        real_write=go.write_report
        before=go.snapshot(self.root/'core')
        original=signal.getsignal(signal.SIGTERM)
        class LateTemp:
            def __init__(self,*args,**kwargs):self.temp=real_temp(*args,**kwargs)
            def __enter__(self):return self.temp.__enter__()
            def __exit__(self,*args):
                result=self.temp.__exit__(*args)
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM,None)
                return result
        def late_write(path,report):
            real_write(path,report)
            if report.get('passed'):
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM,None)
        for phase in ('cleanup','report'):
            with mock.patch.object(go.shutil,'which',return_value=sys.executable), mock.patch.object(go.tempfile,'TemporaryDirectory',LateTemp if phase=='cleanup' else real_temp), mock.patch.object(go,'write_report',late_write if phase=='report' else real_write), self.assertRaises(SystemExit) as raised:
                go.prepare(self.root,runner=lambda *a,**kw:(0,{'outcome':'success'}))
            self.assertEqual(raised.exception.code,143)
            report=json.loads(self.report.read_text(encoding='utf-8'))
            self.assertFalse(report['passed']);self.assertEqual(report['stage'],'cancelled')
            self.assertEqual(go.snapshot(self.root/'core'),before)
            self.assertIs(signal.getsignal(signal.SIGTERM),original)

    def test_durable_report_survives_build_cleanup(self):
        dest=self.root/'batch/diagnostics'
        with mock.patch.object(go.shutil,'which',return_value=sys.executable):
            go.prepare(self.root,runner=lambda *a,**kw:(0,{'outcome':'success'}),environment={'PATH':'','XFLCLASH_DIAGNOSTICS_DIR':str(dest)})
        go.shutil.rmtree(self.root/'build',ignore_errors=True)
        self.assertTrue(json.loads((dest/'dependency-retries/go.json').read_text(encoding='utf-8'))['passed'])

    def test_formal_entries_and_shared_gate(self):
        root=Path(__file__).resolve().parents[2]
        for name in ('.github/workflows/release-package.yml','scripts/package_desktop_local.sh','tool/build_android_local.py'):
            s=(root/name).read_text(encoding='utf-8')
            self.assertIn('--prepare-go',s)
            self.assertIn('prepare_native_build.py',s)
        self.assertIn('tool.test.prepare_go_dependencies_test',(root/'tool/check_release_workflow.py').read_text(encoding='utf-8'))

class ManifestControls(unittest.TestCase):
    def test_only_registered_local_replacement_is_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for replacement,allowed in [({'Path':'./Clash.Meta'},True),({'Path':'../outside'},False),({'Path':'/tmp/outside'},False),({'Path':'example.invalid/module','Version':'v1.0.0'},True)]:
                responses=[mock.Mock(returncode=0,stdout=json.dumps({'Replace':[{'New':replacement}]})),mock.Mock(returncode=0,stdout='{}')]
                with mock.patch.object(go.subprocess,'run',side_effect=responses):
                    if allowed:go.validate_replacements(root,'go',{})
                    else:
                        with self.assertRaises(RuntimeError):go.validate_replacements(root,'go',{})

if __name__=='__main__':unittest.main()
