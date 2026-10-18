#!/usr/bin/env python3
"""Offline subprocess/cleanup tests; never launches Flutter or fetches packages."""
import inspect
import contextlib
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
sys.path.insert(0, str(ROOT / 'tool'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from ready_process_tree import ReadyTree, STARTUP_TIMEOUT
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
        _, unicode_lines = self.classify('测' * 12000 + '\n')
        self.assertEqual(unicode_lines, ['[pub-get output] [oversized line omitted]'])

    def test_environment_keeps_toolchain_and_proxy_but_removes_secrets(self):
        env = retry.clean_environment({'PATH':'fixture', 'PUB_CACHE':'cache', 'https_proxy':'proxy',
            'SENTRY_MAINTENANCE_TOKEN':'secret', 'SDK_READ_TOKEN':'secret', 'GIT_TRACE':'1',
            'GIT_CONFIG_VALUE_0':'Authorization: token', 'XB_AES_KEY':'secret'})
        self.assertEqual(env['PATH'], 'fixture')
        self.assertEqual(env['https_proxy'], 'proxy')
        self.assertEqual(env['GIT_TERMINAL_PROMPT'], '0')
        self.assertFalse(any('TOKEN' in x or 'AES_KEY' in x or x.startswith('GIT_TRACE') for x in env))


class VirtualClock:
    def __init__(self):
        self.now = 100.0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class DeadlineTests(unittest.TestCase):
    def item(self, reason='exit', code=0, cleaned=True, network=()):
        return {'reason':reason, 'exit_code':code, 'cleanup_succeeded':cleaned,
                'elapsed_seconds':0, 'network':list(network), 'permanent':[]}

    def test_production_budgets_are_unchanged(self):
        parameters=inspect.signature(retry.execute).parameters
        for name, expected in {'attempts':3, 'attempt_timeout':300, 'total_timeout':720, 'delays':(10,30)}.items():
            self.assertEqual(parameters[name].default, expected)

    def test_real_attempt_deadline_uses_controlled_clock_without_spawning(self):
        clock=VirtualClock()
        process=mock.Mock(returncode=1)
        process.poll.return_value=None
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(retry,'time',clock), mock.patch.object(retry,'IS_WINDOWS',False), \
             mock.patch.object(retry.subprocess,'Popen',return_value=process), \
             mock.patch.object(retry,'stop_tree',return_value=True) as cleanup:
            result=retry.attempt(['fixture'],Path(directory),{},.25,lambda:0,lambda _:None)
        self.assertEqual(result['reason'],'attempt_timeout')
        self.assertTrue(result['cleanup_succeeded'])
        self.assertGreaterEqual(result['elapsed_seconds'],.25)
        self.assertLessEqual(result['elapsed_seconds'],.27)
        cleanup.assert_called_once()

    def test_timeout_retries_only_after_completed_cleanup_then_success(self):
        clock=VirtualClock(); sequence=[]
        def attempt(command,cwd,env,timeout,*_):
            sequence.append(timeout)
            if len(sequence)==1:
                clock.sleep(timeout)
                return self.item('attempt_timeout',1)
            return self.item()
        with mock.patch.object(retry,'time',clock), mock.patch.object(retry,'attempt',side_effect=attempt):
            code,report=retry.execute(['fixture'],Path('.'),{},emit=lambda _:None)
        self.assertEqual(code,0)
        self.assertEqual(sequence,[300,300])
        self.assertEqual(len(report['attempts']),2)
        self.assertAlmostEqual(report['elapsed_seconds'],310,places=3)

    def test_failed_cleanup_blocks_retry_even_after_timeout(self):
        with mock.patch.object(retry,'time',VirtualClock()), \
             mock.patch.object(retry,'attempt',return_value=self.item('attempt_timeout',1,False)) as attempt:
            code,report=retry.execute(['fixture'],Path('.'),{},emit=lambda _:None)
        self.assertEqual(code,125); self.assertEqual(report['outcome'],'cleanup_failed')
        attempt.assert_called_once()

    def test_budget_exhaustion_prevents_backoff_and_second_attempt(self):
        clock=VirtualClock()
        def attempt(*_):
            clock.sleep(.4)
            return self.item(code=69,network=['connection'])
        with mock.patch.object(retry,'time',clock), mock.patch.object(retry,'attempt',side_effect=attempt) as call:
            code,report=retry.execute(['fixture'],Path('.'),{},total_timeout=.5,delays=(5,),emit=lambda _:None)
        self.assertEqual(code,124); self.assertEqual(report['outcome'],'budget_exhausted')
        self.assertEqual(clock.sleeps,[.4]);call.assert_called_once()

    def test_cancellation_during_virtual_backoff_prevents_retry(self):
        clock=VirtualClock()
        with mock.patch.object(retry,'time',clock), \
             mock.patch.object(retry,'attempt',return_value=self.item(code=69,network=['connection'])) as call:
            code,report=retry.execute(['fixture'],Path('.'),{},
                cancelled=lambda:signal.SIGTERM if clock.now>=100.2 else 0,emit=lambda _:None)
        self.assertEqual(code,143);self.assertEqual(report['outcome'],'cancelled')
        self.assertLess(report['elapsed_seconds'],1);call.assert_called_once()


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
            emit=self.lines.append, delays=(.01,.02), attempt_timeout=15, total_timeout=60, **kwargs)

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

    def ready_tree_attempt(self, *, parent_exits=False, startup_delay=0, timeout_after_ready=False):
        with ReadyTree(self.root, startup_delay=startup_delay) as tree:
            observed_ready = False
            clock = VirtualClock()
            # Jump the deadline only after ready, but keep ticking in real time:
            # WindowsJob.stop also reads retry.time and must retain its bound.
            clock.monotonic = lambda: time.monotonic() + clock.now
            clock.sleep = time.sleep
            def when_ready():
                nonlocal observed_ready
                if not observed_ready and tree.is_ready():
                    tree.assert_alive()
                    observed_ready = True
                    if parent_exits:
                        tree.exit_parent()
                    if timeout_after_ready:
                        clock.now += 300
                return 0 if parent_exits or timeout_after_ready or not observed_ready else signal.SIGTERM
            with mock.patch.object(retry, 'time', clock) if timeout_after_ready else contextlib.nullcontext():
                result = retry.attempt(tree.command, self.root, self.environment,
                                       300 if timeout_after_ready else STARTUP_TIMEOUT + 5,
                                       when_ready, self.lines.append)
            self.assertTrue(observed_ready, json.dumps(result))
            expected = 'attempt_timeout' if timeout_after_ready else 'exit' if parent_exits else 'cancelled'
            self.assertEqual(result['reason'], expected, json.dumps(result))
            if parent_exits:
                self.assertEqual(result['exit_code'], 7)
            self.assertTrue(result['cleanup_succeeded'], json.dumps(result))
            self.assertTrue(result['cleanup_diagnostic']['reaped'])
            tree.assert_closed()
            # A fresh real command must work after cleanup; its budget is for
            # integration startup, not the production timeout decision test.
            self.code('pass\n')
            code, report = self.run_fixture()
            self.assertEqual(code, 0, json.dumps(report))

    def test_ready_parent_and_descendant_are_really_cleaned(self):
        self.ready_tree_attempt()

    def test_slow_startup_does_not_turn_cleanup_test_into_speed_test(self):
        self.ready_tree_attempt(startup_delay=.35)

    def test_timeout_after_readiness_cleans_real_tree_then_allows_new_command(self):
        self.ready_tree_attempt(startup_delay=.35, timeout_after_ready=True)

    def test_parent_exit_does_not_leave_ready_descendant_running(self):
        self.ready_tree_attempt(parent_exits=True)

    def test_termination_witness_rejects_live_processes_negative_control(self):
        with ReadyTree(self.root) as tree:
            process = subprocess.Popen(tree.command, start_new_session=os.name == 'posix')
            try:
                tree.assert_alive()
                with self.assertRaisesRegex(AssertionError, 'still holding'):
                    tree.assert_closed(timeout=.05)
                tree.assert_alive()  # Negative control did not accidentally terminate them.
            finally:
                tree.close()
                process.wait(timeout=5)

    def test_never_started_fixture_cannot_pass_termination_check(self):
        with ReadyTree(self.root) as tree:
            with self.assertRaisesRegex(AssertionError, 'without readiness'):
                tree.assert_closed()

    def test_output_limit_stops_without_retry(self):
        self.code('print("x"*50000)\ntime.sleep(2)\n')
        code, report = self.run_fixture(output_limit=1024)
        self.assertNotEqual(code, 0); self.assertEqual(len(report['attempts']), 1)
        self.assertEqual(report['attempts'][0]['reason'], 'output_limit')

    def test_cleanup_failure_blocks_retry(self):
        self.code('print("Connection reset by peer")\nsys.exit(69)\n')
        original = retry.stop_tree
        def stop(process, job=None, **kwargs):
            original(process, job, **kwargs); return False
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
                phase=self.root/'phase'; phase.unlink(missing_ok=True)
                launcher=self.root/'launch.py'
                launcher.write_text('import importlib.util,sys,os,signal\nfrom pathlib import Path\n'
                    f'sys.path.insert(0,{str(ROOT/"tool")!r})\n'
                    f's=importlib.util.spec_from_file_location("retry",{str(ROOT/"tool/pub_get_retry.py")!r})\n'
                    'r=importlib.util.module_from_spec(s);s.loader.exec_module(r)\nc=[0]\n'
                    'signal.signal(signal.SIGTERM,lambda n,f:c.__setitem__(0,n))\n'
                    f'phase=Path({str(phase)!r})\n'
                    'def emit(line):\n if "retryable dependency failure" in line: phase.write_text("backoff")\n'
                    f'code,report=r.execute([sys.executable,{str(self.script)!r}],Path({str(self.root)!r}),os.environ,cancelled=lambda:c[0],delays=(30,),emit=emit)\n'
                    f'r.write_report(Path({str(self.root/"cancel-report.json")!r}),report)\n'
                    'sys.exit(code)\n')
                process=subprocess.Popen([sys.executable,str(launcher)],env=self.environment,stdout=subprocess.DEVNULL)
                try:
                    marker=phase if "sys.exit(69)" in body else self.count
                    end=time.monotonic()+STARTUP_TIMEOUT
                    while not marker.exists() and time.monotonic()<end:time.sleep(.02)
                    self.assertTrue(marker.exists(), "cancellation phase never became ready")
                    process.send_signal(signal.SIGTERM)
                    actual=process.wait(timeout=8)
                    self.assertEqual(actual,143,(self.root/"cancel-report.json").read_text() if (self.root/"cancel-report.json").exists() else "no report")
                    self.assertEqual(self.count.read_text(),'1')
                finally:
                    if process.poll() is None:process.kill();process.wait()


class WindowsContractTests(unittest.TestCase):
    def test_actual_worker_separates_missing_target_from_exit_127(self):
        with tempfile.TemporaryDirectory(prefix='worker control ') as directory:
            status = Path(directory) / 'status.json'
            commands = [([str(Path(directory)/'absent')], {'state':'launch_failed'}),
                        ([sys.executable,'-c','raise SystemExit(127)'], {'state':'exited','exit_code':127}),
                        ([sys.executable,'-c','pass'], {'state':'exited','exit_code':0})]
            for command, expected in commands:
                with self.subTest(expected=expected):
                    status.unlink(missing_ok=True)
                    result = subprocess.run([sys.executable, str(ROOT/'tool/pub_get_retry.py'),
                        '--worker', json.dumps(command), str(status)], input=b'launch\n',
                        capture_output=True, timeout=10)
                    self.assertEqual(retry.worker_result(status), expected)
                    self.assertNotIn(b'Traceback', result.stderr)

    def test_worker_without_gate_never_starts_target(self):
        with tempfile.TemporaryDirectory() as directory:
            status = Path(directory)/'status.json'
            marker = Path(directory)/'must-not-exist'
            command = [sys.executable,'-c',f'from pathlib import Path;Path({str(marker)!r}).touch()']
            result = subprocess.run([sys.executable,str(ROOT/'tool/pub_get_retry.py'),
                '--worker',json.dumps(command),str(status)], input=b'', capture_output=True, timeout=10)
            self.assertEqual(result.returncode,125)
            self.assertFalse(marker.exists()); self.assertFalse(status.exists())

    def test_corrupt_missing_or_oversized_worker_control_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'status'
            self.assertIsNone(retry.worker_result(path))
            for value in ('{}','{"state":"started"}','{"state":"exited","exit_code":true}',
                          '{"state":"launch_failed","text":"private"}', 'x'*1025):
                path.write_text(value)
                self.assertIsNone(retry.worker_result(path))

    def test_job_stop_error_still_waits_and_records_failure(self):
        process=mock.Mock(returncode=0)
        job=mock.Mock();job.stop.side_effect=OSError('private-token')
        diagnostic={}
        self.assertFalse(retry.stop_tree(process,job,diagnostic=diagnostic))
        process.wait.assert_called_once_with(timeout=3)
        self.assertEqual(diagnostic['outcome'],'failed')
        self.assertNotIn('private',json.dumps(diagnostic))

    def test_job_assignment_precedes_launch_gate(self):
        self.check(False)

    def test_job_assignment_failure_never_launches_pub(self):
        self.check(True)

    def test_parent_uses_control_channel_not_worker_exit_code(self):
        for status, reason, code in (({'state':'launch_failed'}, 'launch_or_io_error', 127),
                                      ({'state':'exited','exit_code':127}, 'exit', 127),
                                      (None, 'worker_protocol_error', 125)):
            with self.subTest(status=status):
                self.check(False, status=status, reason=reason, code=code)

    def check(self, reject, *, status='success', reason='exit', code=0):
        if status == 'success':
            status = {'state':'exited','exit_code':0}
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
             mock.patch.object(retry,'worker_result',return_value=status), \
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
            self.assertEqual(result['exit_code'],code)
            self.assertEqual(result['reason'],reason)
            self.assertEqual(result['cleanup_diagnostic']['outcome'],'complete')
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
