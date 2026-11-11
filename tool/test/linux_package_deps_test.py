"""Real child-process APT fixtures: no sudo, package install, network or native build."""
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install_linux_package_deps as apt
import pub_get_retry


class LinuxPackageDepsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.report = self.root / 'report.json'
        self.calls = self.root / 'calls.jsonl'
        self.fixture = self.root / 'fake_apt.py'
        self.fixture.write_text('''import json, os, sys
from pathlib import Path
args=sys.argv[1:]
source=Path(next(x.split('=',1)[1] for x in args if x.startswith('Dir::Etc::sourcelist=')))
profile=source.parent.name
phase='update' if args[-1]=='update' else 'download' if '--download-only' in args else 'install'
with open(os.environ['CALLS'], 'a') as f:
 f.write(json.dumps({'profile':profile,'phase':phase,'args':args,'sources':source.read_text()})+'\\n')
behavior=json.loads(os.environ['BEHAVIOR']).get(profile+':'+phase,{})
print(behavior.get('output','fixture completed'),flush=True)
sys.exit(behavior.get('code',0))
''', encoding='utf-8')

    def run_fixture(self, behavior, arch='amd64'):
        environment = {**os.environ, 'CALLS': str(self.calls), 'BEHAVIOR': json.dumps(behavior)}
        def runner(command, cwd, env, **options):
            self.assertEqual(command[0], 'apt-get')
            self.assertEqual(options['attempts'], 1)
            return pub_get_retry.execute([sys.executable, str(self.fixture), *command[1:]], cwd, env, **options)
        return apt.install(arch, self.report, runner=runner, environment=environment, emit=lambda _: None)

    def recorded(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_success_keeps_versions_arch_packages_and_offline_install(self):
        for arch, suite, fuse in [('amd64', 'jammy', 'libfuse2'), ('arm64', 'noble', 'libfuse2t64')]:
            with self.subTest(arch=arch):
                self.calls.unlink(missing_ok=True)
                code, report = self.run_fixture({}, arch)
                self.assertEqual(code, 0)
                calls = self.recorded()
                self.assertEqual([c['phase'] for c in calls], ['update', 'download', 'install'])
                for c in calls:
                    self.assertIn('APT::Update::Error-Mode=any', c['args'])
                    self.assertIn('Dir::Etc::sourceparts=-', c['args'])
                    self.assertIn('Dir::Cache::pkgcache=', c['args'])
                    self.assertIn('Dir::Cache::srcpkgcache=', c['args'])
                    self.assertIn('Acquire::Retries=0', c['args'])
                    self.assertIn('Signed-By: ' + apt.KEYRING, c['sources'])
                    self.assertIn('Architectures: ' + arch, c['sources'])
                    self.assertIn(suite + '-security', c['sources'])
                    self.assertNotIn('trusted', c['sources'].lower())
                    self.assertNotIn('--allow-unauthenticated', c['args'])
                self.assertIn('--download-only', calls[1]['args'])
                self.assertIn('--no-download', calls[2]['args'])
                self.assertIn(fuse, calls[2]['args'])
                self.assertEqual('rpm' in calls[2]['args'], arch == 'amd64')
                self.assertTrue(report['passed'])
                self.assertFalse(report['system_sources_changed'])
                self.assertFalse(report['resolver_changed'])
                self.assertEqual(stat.S_IMODE(self.report.stat().st_mode), 0o644)

    def test_update_zero_with_failed_index_never_reaches_install_on_that_profile(self):
        code, report = self.run_fixture({'canonical:update': {'code': 0, 'output':
            "W: Failed to fetch mirror+file:/etc/apt/apt-mirrors.txt/dists/jammy/InRelease Temporary failure resolving 'azure.archive.ubuntu.com'\nW: Some index files failed to download. They have been ignored, or old ones used instead."}})
        self.assertEqual(code, 0)
        self.assertEqual([(x['profile'],x['phase']) for x in self.recorded()],
                         [('canonical','update'),('azure','update'),('azure','download'),('azure','install')])
        self.assertTrue(report['attempts'][0]['soft_index_failure'])
        self.assertEqual(report['attempts'][0]['process']['exit_code'], 0)

    def test_arm_dns_failure_uses_alternate_ports_not_amd64_archive(self):
        code, _ = self.run_fixture({'canonical:update': {'code': 100, 'output': "Temporary failure resolving 'ports.ubuntu.com'"}}, 'arm64')
        self.assertEqual(code, 0)
        self.assertIn('https://azure.ports.ubuntu.com/ubuntu-ports', self.recorded()[-1]['sources'])
        self.assertNotIn('azure.archive.ubuntu.com', self.recorded()[-1]['sources'])

    def test_download_transport_failure_restarts_indexes_on_fresh_profile(self):
        code, _ = self.run_fixture({'canonical:download': {'code': 100, 'output': 'Connection reset by peer'}})
        self.assertEqual(code, 0)
        calls = self.recorded()
        self.assertEqual([c['phase'] for c in calls], ['update','download','update','download','install'])
        first = next(x for x in calls[0]['args'] if x.startswith('Dir::State::lists='))
        second = next(x for x in calls[2]['args'] if x.startswith('Dir::State::lists='))
        self.assertNotEqual(first, second)

    def test_permanent_errors_override_network_and_do_not_fail_over(self):
        for message in ['NO_PUBKEY DEADBEEF', "Clearsigned file isn't valid, got 'NOSPLIT'", 'Release file is expired',
                        'Hash Sum mismatch', 'does not have a Release file',
                        'Unable to locate package fixture', 'Package fixture has no installation candidate',
                        'unmet dependencies', 'certificate verification failed', '403 Forbidden',
                        'Could not get lock /var/lib/dpkg/lock-frontend']:
            with self.subTest(message=message):
                self.calls.unlink(missing_ok=True)
                code, report = self.run_fixture({'canonical:update': {'code': 100, 'output': message + '\nTemporary failure resolving fixture.invalid'}})
                self.assertEqual(code, 100)
                self.assertFalse(report['passed'])
                self.assertEqual(len(self.recorded()), 1)

    def test_signature_warning_with_zero_exit_is_not_accepted(self):
        code, report = self.run_fixture({'canonical:update': {'code': 0, 'output': 'NO_PUBKEY DEADBEEF'}})
        self.assertEqual(code, 100)
        self.assertFalse(report['passed'])
        self.assertEqual(len(self.recorded()), 1)

    def test_unclassified_error_and_unclassified_partial_update_stop(self):
        for output, code in [('Unknown deterministic failure', 17), ('W: Some index files failed to download', 0)]:
            self.calls.unlink(missing_ok=True)
            result, report = self.run_fixture({'canonical:update': {'code': code, 'output': output}})
            self.assertNotEqual(result, 0)
            self.assertFalse(report['passed'])
            self.assertEqual(len(self.recorded()), 1)

    def test_persistent_dns_failure_is_bounded_and_never_installs(self):
        code, report = self.run_fixture({key: {'code':100,'output':'Temporary failure resolving Ubuntu archive'}
                                         for key in ['canonical:update','azure:update']})
        self.assertEqual(code, 100)
        self.assertEqual(len(self.recorded()), 2)
        self.assertFalse(report['passed'])

    def test_install_failure_never_retries_dpkg_even_for_network_diagnostic(self):
        code, report = self.run_fixture({'canonical:install': {'code':100,'output':'Connection timed out'}})
        self.assertEqual(code, 100)
        self.assertEqual(len(self.recorded()), 3)
        self.assertEqual(report['attempts'][-1]['phase'], 'install')

    def test_old_success_report_is_replaced_on_failure(self):
        self.report.write_text('{"passed":true}')
        self.run_fixture({'canonical:update': {'code':1,'output':'Invalid configuration'}})
        self.assertFalse(json.loads(self.report.read_text())['passed'])

    def test_deadline_shared_across_phases(self):
        now=[0.0];calls=[]
        def runner(command,cwd,env,**options):
            calls.append(options);now[0]+=11
            return 0, {'outcome':'success','attempts':[{'cleanup_succeeded':True}]}
        code, report = apt.install('amd64', self.report, runner=runner, clock=lambda:now[0], total_timeout=10, emit=lambda _:None)
        self.assertEqual(code,124)
        self.assertEqual(report['outcome'],'budget_exhausted')
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0]['attempt_timeout'],10)

    def test_cancel_and_cleanup_failure_never_start_another_phase(self):
        for code, outcome in [(143,'cancelled'),(125,'cleanup_failed')]:
            calls=[]
            def runner(*args,**options):
                calls.append(args)
                options['emit']('Temporary failure resolving archive')
                return code, {'outcome':outcome,'attempts':[{'cleanup_succeeded':False,'reason':'attempt_timeout'}]}
            result, report = apt.install('amd64', self.report, runner=runner, emit=lambda _:None)
            self.assertEqual(result,code)
            self.assertFalse(report['passed'])
            self.assertEqual(len(calls),1)

    def test_cancel_before_start_runs_nothing(self):
        def runner(*args, **kwargs):self.fail('Cancelled command ran')
        code, report = apt.install('amd64', self.report, runner=runner, cancelled=lambda:signal.SIGINT)
        self.assertEqual(code,130)
        self.assertEqual(report['attempts'],[])

    def test_dependency_timeout_can_fail_over_but_install_timeout_cannot(self):
        for failed_phase in ('update','install'):
            with self.subTest(phase=failed_phase):
                calls=[]
                def runner(command,cwd,env,**options):
                    phase='update' if command[-1]=='update' else 'download' if '--download-only' in command else 'install'
                    calls.append((cwd.name,phase))
                    failed=cwd.name=='canonical' and phase==failed_phase
                    return (124 if failed else 0), {'outcome':'failed' if failed else 'success','attempts':[
                        {'cleanup_succeeded':True,'reason':'attempt_timeout' if failed else 'exit'}]}
                code, report=apt.install('amd64',self.report,runner=runner,emit=lambda _:None)
                self.assertEqual(code,0 if failed_phase=='update' else 124)
                self.assertEqual(report['passed'],failed_phase=='update')
                self.assertEqual(any(profile=='azure' for profile,_ in calls),failed_phase=='update')

    def test_host_identity_rejects_runner_upgrade_or_wrong_architecture(self):
        for arch, version, suite in [('amd64','22.04','jammy'),('arm64','24.04','noble')]:
            content=f'ID=ubuntu\nVERSION_ID="{version}"\nVERSION_CODENAME={suite}\n'
            with mock.patch.object(Path,'read_text',return_value=content),mock.patch.object(Path,'is_file',return_value=True),mock.patch.object(apt.os,'geteuid',return_value=0),mock.patch.object(apt.subprocess,'check_output',return_value=arch+'\n'):
                apt.validate_host(arch)
                with self.assertRaises(RuntimeError):apt.validate_host('arm64' if arch=='amd64' else 'amd64')

    def test_formal_workflow_wires_bounded_installer_and_both_evidence_paths(self):
        root=Path(__file__).resolve().parents[2]
        workflow=(root/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        step=workflow.split('      - name: Install Linux package deps\n',1)[1].split('\n      - name:',1)[0]
        self.assertIn('timeout-minutes: 15',step)
        self.assertIn('sudo python3 tool/install_linux_package_deps.py',step)
        self.assertIn('--arch "${{ matrix.arch }}"',step)
        self.assertNotIn('||',step)
        self.assertIn('--report "$RUNNER_TEMP/linux-package-deps.json"',step)
        self.assertEqual(workflow.count('            build/dependency-retries/'),2)
        self.assertIn('"os":"ubuntu-22.04","arch":"amd64"',workflow)
        self.assertIn('"os":"ubuntu-24.04-arm","arch":"arm64"',workflow)

    def test_always_capture_preserves_report_after_build_directory_is_removed(self):
        root=Path(__file__).resolve().parents[2]
        workflow=(root/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        block=workflow.split('      - name: Capture native hook input change diagnostics\n',1)[1].split('\n      - name:',1)[0]
        self.assertIn('if: always()',block)
        script='\n'.join(line[10:] for line in block.split('        run: |\n',1)[1].splitlines())
        temporary=self.root/'runner-temp';temporary.mkdir()
        (temporary/'linux-package-deps.json').write_text('{"passed":false,"outcome":"failed"}')
        result=subprocess.run(['bash','-c',script],cwd=self.root,
            env={**os.environ,'RUNNER_TEMP':str(temporary)},capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads((self.root/'build/dependency-retries/linux-apt.json').read_text()),
                         {'passed':False,'outcome':'failed'})


if __name__=='__main__':
    unittest.main()
