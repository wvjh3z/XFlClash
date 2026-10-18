#!/usr/bin/env python3
"""Offline subprocess/cleanup tests; never launches Flutter or fetches packages."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pub_retry', ROOT / 'tool/pub_get_retry.py')
retry = importlib.util.module_from_spec(spec); spec.loader.exec_module(retry)


class ClassifierTests(unittest.TestCase):
    def classify(self, value):
        lines = []
        result = retry.Output(lines.append, {})
        for part in [value[:7], value[7:21], value[21:]]:
            result.feed(part.encode())
        result.feed(b'', final=True)
        return result, lines

    def test_real_84_diagnostic_is_network_not_exit_code_guess(self):
        result, _ = self.classify('Git error.\nerror: RPC failed; curl 56 Recv failure: Operation timed out\n'
                                  'fetch-pack: unexpected disconnect while reading sideband packet\nfatal: early EOF\n'
                                  'fatal: fetch-pack: invalid index-pack output\nexit code: 128\nFailed to update packages.')
        self.assertIn('git_transport', result.categories['network'])
        self.assertFalse(result.categories['permanent'])
        result, _ = self.classify('Failed to update packages. exit code: 69')
        self.assertFalse(result.categories['network'])

    def test_network_classes(self):
        for text in ['Failed host lookup: pub.dev', 'Could not resolve host: github.com',
                     'ENOTFOUND', 'EAI_AGAIN', 'Connection reset by peer',
                     'HTTP 503 Service Unavailable', 'The requested URL returned error: 429']:
            with self.subTest(text=text):
                result, _ = self.classify(text)
                self.assertTrue(result.categories['network'])
                self.assertFalse(result.categories['permanent'])

    def test_permanent_failures_win_over_earlier_network_noise(self):
        for text in ['version solving failed', 'Authentication failed', 'Permission denied',
                     'could not read Username: terminal prompts disabled', 'Repository not found',
                     'SSL certificate problem: certificate has expired', 'CERTIFICATE_VERIFY_FAILED',
                     'The requested URL returned error: 403', 'Received HTTP code 407 from proxy',
                     'No space left on device',
                     'Could not find a file named "pubspec.yaml"', "couldn't find remote ref pinned",
                     'The requested URL returned error: 404', 'requires SDK version >=9.0.0']:
            with self.subTest(text=text):
                result, _ = self.classify('Connection reset by peer\n'+text)
                self.assertTrue(result.categories['permanent'])

    def test_masking_across_chunks_and_workflow_command_injection(self):
        lines = []
        output = retry.Output(lines.append, {'SENTRY_AUTH_TOKEN': 'fixture-env-secret'})
        text = '::error:: https://user:password@git.invalid/repo?token=fixture-query Authorization: Bearer fixture-bearer fixture-env-secret\n'
        for byte in text.encode():
            output.feed(bytes([byte]))
        output.feed(b'', final=True)
        joined = '\n'.join(lines)
        for value in ['user:password', 'fixture-query', 'fixture-bearer', 'fixture-env-secret', '::error::']:
            self.assertNotIn(value, joined)
        self.assertIn('git.invalid/repo', joined)

    def test_quoted_credentials_and_known_token_prefixes_are_masked(self):
        result, lines = self.classify('{"token": "fixture-json", "password": "fixture-password"} sntrys_fixtureencoded ghp_fixtureencoded\n')
        text=''.join(lines)
        for value in ['fixture-json','fixture-password','sntrys_fixtureencoded','ghp_fixtureencoded']:
            self.assertNotIn(value,text)

    def test_long_line_is_not_printed_in_pieces_and_keeps_classification(self):
        result, lines = self.classify('secret-prefix ' + 'x' * 100000 + ' version solving failed\n')
        self.assertIn('dependency_resolution', result.categories['permanent'])
        self.assertEqual(lines, ['[pub-get output] [oversized line omitted]'])

    def test_environment_keeps_toolchain_and_proxy_but_removes_secrets(self):
        env = retry.clean_environment({'PATH':'fixture', 'PUB_CACHE':'cache', 'https_proxy':'proxy',
            'SENTRY_MAINTENANCE_TOKEN':'secret', 'SDK_READ_TOKEN':'secret', 'GIT_TRACE':'1',
            'GIT_CONFIG_VALUE_0':'Authorization: token', 'XB_AES_KEY':'secret'})
        self.assertEqual(env['PATH'], 'fixture')
        self.assertEqual(env['https_proxy'], 'proxy')
        self.assertEqual(env['GIT_TERMINAL_PROMPT'], '0')
        self.assertFalse(any('TOKEN' in x or 'AES_KEY' in x or x.startswith('GIT_TRACE') for x in env))


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pub retry fixture ')
        self.root = Path(self.temp.name)
        self.lines = []
        self.script = self.root/'fixture.py'
        self.count = self.root/'count'
        self.environment = dict(os.environ)
        self.environment['FIXTURE_COUNTER'] = str(self.count)

    def tearDown(self):
        self.temp.cleanup()

    def code(self, body):
        self.script.write_text('import os,sys,time,subprocess\nfrom pathlib import Path\n'
            'counter=Path(os.environ["FIXTURE_COUNTER"])\n'
            'n=int(counter.read_text())+1 if counter.exists() else 1\n'
            'counter.write_text(str(n))\n'+body, encoding='utf-8')

    def run_fixture(self, **kwargs):
        return retry.execute([sys.executable, str(self.script)], self.root, self.environment,
            emit=self.lines.append, delays=(.01,.02), attempt_timeout=2, total_timeout=6, **kwargs)

    def test_success_no_retry_despite_warning(self):
        self.code('print("Connection reset by peer was recovered")\n')
        code, report = self.run_fixture()
        self.assertEqual(code, 0); self.assertEqual(self.count.read_text(), '1')
        self.assertEqual(report['outcome'], 'success')

    def test_two_network_failures_then_success(self):
        self.code('print("RPC failed; curl 56 Recv failure: Operation timed out", flush=True)\n'
                  'sys.exit(69 if n<3 else 0)\n')
        code, report = self.run_fixture()
        self.assertEqual(code, 0); self.assertEqual(self.count.read_text(), '3')
        self.assertEqual(len(report['attempts']), 3)
        self.assertTrue(all(x['cleanup_succeeded'] for x in report['attempts']))

    def test_retry_limit_preserves_last_exit(self):
        self.code('print("Failed host lookup: fixture.invalid")\nsys.exit(69)\n')
        code, report = self.run_fixture()
        self.assertEqual(code, 69); self.assertEqual(self.count.read_text(), '3')
        self.assertEqual(report['attempts'][-1]['exit_code'], 69)
        self.assertIn('Failed host lookup', '\n'.join(self.lines))

    def test_unknown_69_is_not_retried(self):
        self.code('print("Failed to update packages.")\nsys.exit(69)\n')
        code, report = self.run_fixture()
        self.assertEqual(code, 69); self.assertEqual(len(report['attempts']), 1)

    def test_deterministic_failure_does_not_retry(self):
        self.code('print("Connection reset by peer\\nBecause fixture requires SDK version >=9, version solving failed.")\nsys.exit(1)\n')
        code, report = self.run_fixture()
        self.assertEqual(code, 1); self.assertEqual(len(report['attempts']), 1)

    def descendant(self, marker):
        return 'import time;from pathlib import Path;time.sleep(.8);Path('+repr(str(marker))+').write_text("escaped")'

    def test_timeout_can_retry_after_cleaning_owned_process_tree(self):
        marker = self.root/'orphan'
        child = self.descendant(marker)
        self.code('if n==1:\n'
                  f' subprocess.Popen([sys.executable,"-c",{child!r}])\n'
                  ' time.sleep(10)\n')
        code, report = retry.execute([sys.executable,str(self.script)],self.root,self.environment,
            attempts=2,attempt_timeout=.25,total_timeout=3,delays=(.01,),emit=self.lines.append)
        self.assertEqual(code, 0); self.assertEqual(len(report['attempts']), 2)
        self.assertEqual(report['attempts'][0]['reason'], 'attempt_timeout')
        time.sleep(.85)
        self.assertFalse(marker.exists(), 'owned descendant survived timeout')

    def test_parent_exit_does_not_leave_child_inheriting_output_or_cache_work(self):
        marker = self.root/'orphan'
        child = self.descendant(marker)
        self.code(f'subprocess.Popen([sys.executable,"-c",{child!r}])\n'
                  'print("unknown failure")\nsys.exit(1)\n')
        code, report = self.run_fixture()
        self.assertEqual(code, 1); self.assertTrue(report['attempts'][0]['cleanup_succeeded'])
        time.sleep(.85)
        self.assertFalse(marker.exists(), 'descendant survived parent exit')

    def test_output_limit_stops_without_retry(self):
        self.code('print("x"*50000)\ntime.sleep(2)\n')
        code, report = self.run_fixture(output_limit=1024)
        self.assertNotEqual(code, 0); self.assertEqual(len(report['attempts']), 1)
        self.assertEqual(report['attempts'][0]['reason'], 'output_limit')

    def test_budget_prevents_sleep_and_next_attempt(self):
        self.code('print("Connection reset by peer")\nsys.exit(69)\n')
        code, report = retry.execute([sys.executable,str(self.script)],self.root,self.environment,
            total_timeout=.5,delays=(5,),emit=self.lines.append)
        self.assertEqual(code, 124); self.assertEqual(len(report['attempts']), 1)
        self.assertLess(report['elapsed_seconds'], 2)

    def test_cleanup_failure_blocks_retry(self):
        self.code('print("Connection reset by peer")\nsys.exit(69)\n')
        original = retry.stop_tree
        def stop(process, job=None):
            original(process, job); return False
        with mock.patch.object(retry,'stop_tree',side_effect=stop):
            code, report = self.run_fixture()
        self.assertEqual(code, 125); self.assertEqual(len(report['attempts']), 1)
        self.assertEqual(report['outcome'], 'cleanup_failed')

    def test_missing_executable_does_not_retry(self):
        code, report = retry.execute([str(self.root/'absent')],self.root,self.environment,emit=self.lines.append)
        self.assertNotEqual(code, 0); self.assertEqual(len(report['attempts']), 1)
        self.assertEqual(report['attempts'][0]['reason'], 'launch_or_io_error')

    def test_windows_native_crash_is_not_retried_after_network_warning(self):
        item={'reason':'exit','exit_code':0xC0000005,'cleanup_succeeded':True,'elapsed_seconds':0,'network':['connection'],'permanent':[]}
        with mock.patch.object(retry,'attempt',return_value=item) as call:
            code,report=self.run_fixture()
        self.assertEqual(code,255)
        self.assertEqual(report['outcome'],'process_crash')
        call.assert_called_once()

    @unittest.skipIf(os.name=='nt','POSIX signal termination')
    def test_child_killed_by_signal_never_retries(self):
        self.code('import signal\nprint("Connection reset by peer",flush=True)\nos.kill(os.getpid(),signal.SIGKILL)\n')
        code,report=self.run_fixture()
        self.assertEqual(code,137)
        self.assertEqual(report['outcome'],'process_crash')
        self.assertEqual(len(report['attempts']),1)

    def test_cancel_before_attempt(self):
        self.code('raise RuntimeError("must not start")\n')
        code, report = self.run_fixture(cancelled=lambda: signal.SIGTERM)
        self.assertEqual(code, 143); self.assertFalse(report['attempts']); self.assertFalse(self.count.exists())

    @unittest.skipIf(os.name=='nt', 'POSIX cancellation signals; Windows Job lifecycle uses other process tests')
    def test_signal_cancellation_during_process_and_backoff(self):
        for body in ['time.sleep(30)', 'print("Connection reset by peer",flush=True)\nsys.exit(69)']:
            with self.subTest(body=body):
                self.code(body+'\n'); self.count.unlink(missing_ok=True)
                launcher=self.root/'launch.py'
                launcher.write_text('import importlib.util,sys,os,signal\nfrom pathlib import Path\n'
                    f's=importlib.util.spec_from_file_location("retry",{str(ROOT/"tool/pub_get_retry.py")!r})\n'
                    'r=importlib.util.module_from_spec(s);s.loader.exec_module(r)\nc=[0]\n'
                    'signal.signal(signal.SIGTERM,lambda n,f:c.__setitem__(0,n))\n'
                    f'code,report=r.execute([sys.executable,{str(self.script)!r}],Path({str(self.root)!r}),os.environ,cancelled=lambda:c[0],delays=(30,),emit=lambda s:print(s,flush=True))\n'
                    'sys.exit(code)\n')
                process=subprocess.Popen([sys.executable,str(launcher)],env=self.environment,stdout=subprocess.DEVNULL)
                try:
                    end=time.monotonic()+4
                    while not self.count.exists() and time.monotonic()<end:time.sleep(.02)
                    self.assertTrue(self.count.exists())
                    time.sleep(.25); process.send_signal(signal.SIGTERM)
                    self.assertEqual(process.wait(timeout=5),143)
                    self.assertEqual(self.count.read_text(),'1')
                finally:
                    if process.poll() is None:process.kill();process.wait()


class WindowsContractTests(unittest.TestCase):
    def test_job_assignment_precedes_launch_gate(self):
        self.check(False)

    def test_job_assignment_failure_never_launches_pub(self):
        self.check(True)

    def check(self, reject):
        events=[]
        job=mock.Mock()
        job.assign.side_effect=lambda process: events.append('assign')
        if reject:
            job.assign.side_effect=OSError('fixture assignment rejected')
        job.stop.return_value=True
        process=mock.Mock()
        process.stdin.write.side_effect=lambda data:events.append(('gate',data))
        process.poll.return_value=0
        process.returncode=0
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(retry,'IS_WINDOWS',True), \
             mock.patch.object(retry,'WindowsJob',return_value=job), \
             mock.patch.object(retry.subprocess,'CREATE_NEW_PROCESS_GROUP',512,create=True), \
             mock.patch.object(retry.subprocess,'CREATE_NO_WINDOW',0x08000000,create=True), \
             mock.patch.object(retry.subprocess,'Popen',return_value=process) as launch:
            result=retry.attempt(['fixture-flutter.bat','pub','get'],Path(directory),{},1,lambda:0,lambda line:None)
        if reject:
            process.stdin.write.assert_not_called()
            process.kill.assert_called_once()
            self.assertEqual(result['reason'],'launch_or_io_error')
        else:
            self.assertEqual(events,['assign',('gate',b'launch\n')])
            self.assertIn('--worker',launch.call_args.args[0])
            self.assertEqual(result['exit_code'],0)
        job.stop.assert_called_once();job.close.assert_called_once()


class InterfaceTests(unittest.TestCase):
    def test_cli_cannot_wrap_build_or_arbitrary_shell(self):
        for argv in [['--tool','flutter build'], ['--tool','flutter','--report','x','--','build','apk']]:
            with mock.patch('sys.stderr'), self.assertRaises(SystemExit) as error:
                retry.main(argv)
            self.assertEqual(error.exception.code,2)

    def test_real_cli_uses_only_pub_get_and_writes_summary(self):
        with tempfile.TemporaryDirectory(prefix='pub cli fixture ') as directory:
            root=Path(directory)
            if os.name=='nt':
                executable=root/'flutter.bat'
                executable.write_text('@echo off\nif not "%1 %2"=="pub get" exit /b 99\necho offline fixture\nexit /b 0\n')
            else:
                executable=root/'flutter'
                executable.write_text('#!'+sys.executable+'\nimport sys\nassert sys.argv[1:]==["pub","get"]\nprint("offline fixture")\n')
                executable.chmod(0o755)
            report=root/'report.json'
            result=subprocess.run([sys.executable,str(ROOT/'tool/pub_get_retry.py'),'--tool','flutter','--cwd',str(root),'--report',str(report)],
                env={**os.environ,'PATH':str(root)+os.pathsep+os.environ['PATH']},capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('offline fixture',result.stdout)
            data=json.loads(report.read_text())
            self.assertEqual(data['tool'],'flutter')
            self.assertEqual(data['outcome'],'success')
            self.assertEqual(len(data['attempts']),1)

    def test_workflows_bound_explicit_downloads_not_builds(self):
        release=(ROOT/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        ci=(ROOT/'.github/workflows/xboard-ci.yml').read_text(encoding='utf-8')
        self.assertEqual(release.count('pub_get_retry.py --tool')+release.count('pub_get_retry.py" --tool'),3)
        self.assertEqual(ci.count('pub_get_retry.py" --tool')+ci.count('pub_get_retry.py --tool'),2)
        self.assertNotIn('          flutter pub get',release)
        self.assertNotIn('          dart pub get',release)
        self.assertIn('          dart run build_runner build',release)
        self.assertIn('build/dependency-retries/',release)
        self.assertIn('if: always()',ci)

    def test_report_has_no_raw_command_or_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            report={'schema_version':1,'outcome':'failed','attempts':[{'network':['dns'],'permanent':[]}]}
            path=Path(directory)/'report.json';retry.write_report(path,report)
            self.assertEqual(json.loads(path.read_text()),report)
            if os.name!='nt':self.assertEqual(path.stat().st_mode&0o777,0o600)

    @unittest.skipIf(os.name=='nt','symlink creation requires privileges')
    def test_report_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/'keep';target.write_text('untouched')
            link=Path(directory)/'report';link.symlink_to(target)
            with self.assertRaises(OSError):retry.write_report(link,{})
            self.assertEqual(target.read_text(),'untouched')


if __name__=='__main__':
    unittest.main()
