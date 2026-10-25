"""Real Git/child-process controls for cold orchestration; no network/client build.

Dart's pub/CLI boundary is a harmless Python executable. Actual production
preparation, graph checks, empty caches, stage ordering and cleanup still run.
The separate cold CLI executes real Dart and platform tools in release CI.
"""
from contextlib import contextmanager
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import distributor_preflight as entry

ROOT = Path(__file__).resolve().parents[2]
PUB = r'''
import json, os, pathlib, sys
root = pathlib.Path.cwd()
cache = pathlib.Path(os.environ['PUB_CACHE']); cache.mkdir(parents=True,exist_ok=True)
args = sys.argv[1:]; mode = os.environ.get('FIXTURE_FAILURE', '')
tool = root/'build/packaging-tools/flutter_distributor/packages/flutter_distributor'
if args[:2] == ['global', 'activate']:
    assert not list(cache.iterdir()), 'cache was not empty'
    if mode == 'activation': sys.exit(23)
    packages = tool.parent
    graph = tool/'.dart_tool/package_config.json'; graph.parent.mkdir()
    names = ['flutter_distributor','flutter_app_builder','flutter_app_packager',
             'flutter_app_publisher','parse_app_package','shell_executor']
    rows = [{'name': name,'rootUri':(packages/name).as_uri(),'packageUri':'lib/'} for name in names]
    if mode == 'graph': rows[0]['rootUri'] = (root/'plugins/flutter_distributor/packages/flutter_distributor').as_uri()
    graph.write_text(json.dumps({'packages':rows}),encoding='utf-8')
    (cache/'activation').write_text(str(tool if mode != 'wrong-global' else root/'old'),encoding='utf-8')
elif args == ['global','list']:
    print('flutter_distributor 0.3.7 at path "'+(cache/'activation').read_text(encoding='utf-8')+'"')
elif args == ['global','run','flutter_distributor:main','--help']:
    if mode == 'cli': sys.exit(24)
    print('wrong tool' if mode == 'help' else 'Usage: flutter_distributor <command>\n  package  Package apps')
else: raise RuntimeError(args)
'''


def git(root, *args):
    return subprocess.run(['git','-C',str(root),*map(str,args)],check=True,capture_output=True,timeout=30).stdout


class ColdStartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cold-regression-中文-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve(); self.root = self.base/'source'; self.root.mkdir()
        git(self.root,'init','--quiet','--template=')
        for path in ('tool/distributor_preflight.py','tool/prepare_linux_packager.py',
                     'tool/patches/flutter_distributor_appimage.patch', 'tool/checkout_distributor.py',
                     'tool/pub_get_retry.py', 'tool/owned_process_cleanup.py'):
            dest = self.root/path; dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/path,dest)
        (self.root/'pub').write_text(PUB,encoding='utf-8')
        probe = self.root/'tool/test/packager_context_test.py'; probe.parent.mkdir()
        probe.write_text("import os,sys\nsys.exit(25 if os.environ.get('FIXTURE_FAILURE') == 'platform' else 0)\n",encoding='utf-8')
        (self.root/'.gitignore').write_text('build/\n.dart_tool/\n.local-build/\n',encoding='utf-8')
        from checkout_distributor import RELATIVE, URL
        module = self.root / RELATIVE
        module.parent.mkdir(parents=True)
        source = ROOT / RELATIVE
        subprocess.run(['git','clone','--quiet','--shared',str(source),str(module)],check=True,capture_output=True)
        fetch = self.root/'tool/checkout_distributor.py'
        fetch.write_text(fetch.read_text(encoding='utf-8').replace(repr(URL),repr(source.as_uri())),encoding='utf-8')
        git(self.root,'add','tool','pub','.gitignore')
        git(self.root,'-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','fixture')
        self.report=self.base/'reports/cold.json'
        self.env={**os.environ,'PUB_CACHE':str(self.base/'old-cache')}
        self.target={'linux':'android','darwin':'macos','win32':'windows'}[sys.platform]

    def run_cold(self, mode=''):
        runner=entry.Runner(self.report)
        env={**self.env,'FIXTURE_FAILURE':mode}
        commands=[('context',[sys.executable,'tool/test/packager_context_test.py'],30)]
        factory=tempfile.TemporaryDirectory
        cold_paths=[]
        def tracked_temp(*args,**kwargs):
            result=factory(*args,**kwargs)
            if kwargs.get('prefix') == 'distributor-cold-': cold_paths.append(Path(result.name))
            return result
        try:
            with mock.patch.object(entry,'native_dart',return_value=sys.executable), \
                 mock.patch.object(entry,'platform_commands',return_value=commands), \
                 mock.patch.object(entry,'validate_host'), \
                 mock.patch.object(entry.tempfile,'TemporaryDirectory',side_effect=tracked_temp):
                entry.cold_start(self.root,env,runner,self.target)
        finally:
            self.assertTrue(cold_paths)
            self.assertTrue(all(not path.exists() for path in cold_paths), 'cold workspace leaked')
        return runner

    def test_real_cold_clone_ignores_old_graphs_and_cache_and_restores_source(self):
        for relative in ('build/poison','.dart_tool/package_config.json','.local-build/poison',
                         'plugins/flutter_distributor/packages/flutter_distributor/.dart_tool/package_config.json'):
            p=self.root/relative;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'old invalid cache')
        old=Path(self.env['PUB_CACHE']);old.mkdir();(old/'activation').write_bytes(b'wrong tool')
        index=(self.root/'.git/index').read_bytes()
        runner=self.run_cold()
        self.assertTrue(runner.data['initial_cache_empty'])
        self.assertTrue(runner.data['temporary_workspace_removed'])
        labels=[row['name'] for row in runner.data['steps']]
        self.assertEqual(labels[-5:],['prepare','activate','global-list','global-cli','context'])
        self.assertEqual((old/'activation').read_bytes(),b'wrong tool')
        self.assertEqual((self.root/'build/poison').read_bytes(),b'old invalid cache')
        self.assertEqual((self.root/'.git/index').read_bytes(),index)

    def test_failures_stop_before_later_phases_and_never_report_success(self):
        for failure,last in [('activation','activate'),('graph','activate'),('wrong-global','global-list'),
                             ('cli','global-cli'),('help','global-cli'),('platform','context')]:
            with self.subTest(failure=failure):
                self.report.parent.mkdir(exist_ok=True)
                self.report.write_text('{"passed":true}',encoding='utf-8')
                with self.assertRaises(RuntimeError): self.run_cold(failure)
                report=json.loads(self.report.read_text(encoding='utf-8'))
                self.assertFalse(report['passed'])
                self.assertEqual(report['steps'][-1]['name'],last)

    def test_uncommitted_entrypoint_mismatch_fails_before_activation(self):
        (self.root/'tool/distributor_preflight.py').write_bytes(b'outdated entrypoint')
        git(self.root,'add','tool/distributor_preflight.py')
        git(self.root,'-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','old')
        with self.assertRaisesRegex(entry.PreflightError,'revision_does_not_match_entrypoint'):self.run_cold()
        report=json.loads(self.report.read_text(encoding='utf-8'))
        self.assertNotIn('activate',[s['name'] for s in report['steps']])

    def test_shallow_parent_and_submodule_match_clean_runner_history(self):
        source=self.root
        shallow=self.base/'shallow'
        subprocess.run(['git','clone','--quiet','--depth=1',source.as_uri(),str(shallow)],check=True,capture_output=True)
        self.assertEqual(git(shallow,'rev-parse','--is-shallow-repository').strip(),b'true')
        self.root=shallow
        self.assertTrue(self.run_cold().data['temporary_workspace_removed'])

    def test_missing_immutable_tool_commit_fails_before_activation(self):
        source=self.root/'tool/prepare_linux_packager.py'
        from prepare_linux_packager import PINNED_REVISION
        source.write_text(source.read_text(encoding='utf-8').replace(PINNED_REVISION,'1'*40),encoding='utf-8')
        git(self.root,'add','tool/prepare_linux_packager.py')
        git(self.root,'-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','bad pin')
        with self.assertRaisesRegex(entry.PreflightError,'stage_failed:prepare'):self.run_cold()
        data=json.loads(self.report.read_text(encoding='utf-8'))
        self.assertFalse(data['passed'])
        self.assertNotIn('activate',[s['name'] for s in data['steps']])

    def test_public_entrypoint_marks_success_and_failure_without_stale_evidence(self):
        commands=[('context',[sys.executable,'tool/test/packager_context_test.py'],30)]
        for mode,expected in [('',0),('cli',1)]:
            with mock.patch.object(entry,'ROOT',self.root), \
                 mock.patch.object(entry,'native_dart',return_value=sys.executable), \
                 mock.patch.object(entry,'platform_commands',return_value=commands), \
                 mock.patch.dict(os.environ,{**self.env,'FIXTURE_FAILURE':mode}):
                code=entry.main(['cold','--platform',self.target,'--report',str(self.report)])
            self.assertEqual(code,expected)
            report=json.loads(self.report.read_text(encoding='utf-8'))
            self.assertEqual(report['passed'],expected==0)
            self.assertFalse(report['client_build'])

    def test_final_cleanup_failure_cannot_report_success(self):
        # Inject at our context-manager boundary, not at global os.unlink:
        # stdlib callback/retry implementation changes between Python patches.
        factory = tempfile.TemporaryDirectory
        paths = []
        commands = [('context', [sys.executable, 'tool/test/packager_context_test.py'], 30)]
        for error_type in (None, PermissionError, OSError):
            with self.subTest(cleanup_error=error_type):
                @contextmanager
                def temporary(*args, **kwargs):
                    with factory(*args, **kwargs) as directory:
                        if kwargs.get('prefix') == 'distributor-cold-':
                            paths.append(Path(directory))
                        yield directory
                    if kwargs.get('prefix') == 'distributor-cold-' and error_type:
                        raise error_type(errno.EACCES if error_type is PermissionError else errno.EIO,
                                         'controlled final cleanup failure')

                self.report.parent.mkdir(exist_ok=True)
                self.report.write_text('{"passed":true,"temporary_workspace_removed":true}', encoding='utf-8')
                with mock.patch.object(entry, 'ROOT', self.root), \
                     mock.patch.object(entry, 'native_dart', return_value=sys.executable), \
                     mock.patch.object(entry, 'platform_commands', return_value=commands), \
                     mock.patch.object(entry, 'validate_host'), \
                     mock.patch.object(entry.tempfile, 'TemporaryDirectory', side_effect=temporary), \
                     mock.patch.dict(os.environ, {**self.env, 'FIXTURE_FAILURE': ''}):
                    code = entry.main(['cold', '--platform', 'android', '--report', str(self.report)])
                report = json.loads(self.report.read_text(encoding='utf-8'))
                self.assertEqual(code, 1 if error_type else 0)
                self.assertEqual(report['passed'], error_type is None)
                self.assertEqual(report.get('temporary_workspace_removed', False), error_type is None)
                self.assertEqual(report['steps'][-1]['name'], 'context')
                self.assertEqual(report['steps'][-1]['exit_code'], 0)
                self.assertEqual(report.get('error'), error_type.__name__ if error_type else None)
                self.assertFalse(report['client_build'])
                self.assertTrue(paths)
                self.assertTrue(all(not path.exists() for path in paths), 'test workspace leaked')

    def test_same_entrypoint_with_crlf_checkout_is_accepted(self):
        path=self.root/'tool/distributor_preflight.py'
        path.write_text(path.read_text(encoding='utf-8'),encoding='utf-8',newline='\r\n')
        git(self.root,'-c','core.autocrlf=false','add','tool/distributor_preflight.py')
        git(self.root,'-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','CRLF')
        self.assertIn(b'\r\n',git(self.root,'show','HEAD:tool/distributor_preflight.py'))
        runner=self.run_cold()
        self.assertTrue(runner.data['temporary_workspace_removed'])

    def test_dirty_source_refused_before_pub_activation(self):
        # Direct formal entry also fails closed; cold cloning cannot conceal a
        # modified submodule used by the actual production activation.
        from checkout_distributor import RELATIVE
        source=self.root/RELATIVE/'packages/flutter_distributor/pubspec.yaml'
        source.write_bytes(source.read_bytes()+b'\nchanged\n')
        runner=entry.Runner(self.report)
        with mock.patch.object(entry,'native_dart',return_value=sys.executable):
            with self.assertRaisesRegex(entry.PreflightError,'stage_failed:prepare'):
                entry.activate(self.root,self.env,runner)
        self.assertEqual([s['name'] for s in runner.data['steps']],['prepare'])


class EntryContractTests(unittest.TestCase):
    def test_platform_plans_include_real_preflights_and_never_client_builds(self):
        expected={'android':['brand-identity','context','flutter-defines','android-arguments','android-artifacts'],
                  'linux':['brand-identity','context','flutter-defines','appimage-contract','update-handoff','crisp-appimage-browser','linux-maker'],
                  'windows':['brand-identity','context','flutter-defines','windows-branded-cmake','windows-iscc'],'macos':['brand-identity','context','flutter-defines']}
        for platform,labels in expected.items():
            plan=entry.platform_commands(platform,dart='native-dart')
            self.assertEqual([row[0] for row in plan],['crisp-compatibility', *labels])
            self.assertTrue(all(row[1][0] == ('native-dart' if row[0] in ('update-handoff','crisp-appimage-browser') else sys.executable) for row in plan))
            if platform == 'linux':
                handoff = next(row[1] for row in plan if row[0] in ('update-handoff','crisp-appimage-browser'))
                self.assertEqual(handoff[1], '--packages=build/packaging-tools/flutter_distributor/packages/flutter_distributor/.dart_tool/package_config.json')
                self.assertEqual(handoff[2], 'tool/test/update_handoff_test.dart')
            self.assertTrue(all('release_pipeline.py' not in ' '.join(map(str,row[1])) for row in plan))
            if platform == 'linux':
                maker = next(row[1] for row in plan if row[0] == 'linux-maker')
                self.assertIn('tool.test.linux_release_packages_test', maker)
                self.assertIn('tool.test.linux_appimage_readback_test', maker)

    def test_cold_environment_drops_credentials_python_injection_and_all_old_caches(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary)
            env=entry.isolated_environment(base,{'PATH':'known','PUB_CACHE':'old','PYTHONPATH':'old',
                'SENTRY_AUTH_TOKEN':'hidden','GITHUB_ENV':'must-not-write','GIT_CONFIG_COUNT':'1'})
            self.assertNotIn('SENTRY_AUTH_TOKEN',env);self.assertNotIn('PYTHONPATH',env)
            self.assertNotIn('GITHUB_ENV',env);self.assertNotIn('GIT_CONFIG_COUNT',env)
            self.assertEqual(Path(env['PUB_CACHE']),base/'pub-cache')
            self.assertFalse(list(Path(env['PUB_CACHE']).iterdir()))

    def test_runner_timeout_and_failure_overwrite_stale_passed_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);report=root/'report.json';report.write_text('{"passed":true}',encoding='utf-8')
            runner=entry.Runner(report)
            with self.assertRaises(entry.PreflightError):
                runner.run('timeout',[sys.executable,'-c','import time; time.sleep(30)'],root,os.environ,.2)
            data=json.loads(report.read_text(encoding='utf-8'));self.assertFalse(data['passed'])
            self.assertEqual(data['steps'][0]['attempts'][0]['reason'],'attempt_timeout')
            self.assertTrue(data['steps'][0]['attempts'][0]['cleanup_succeeded'])

    def test_native_host_guard_precedes_clone_and_network(self):
        with mock.patch.object(entry.sys,'platform','linux'):
            with self.assertRaises(entry.PreflightError):entry.validate_host('macos')
            with self.assertRaises(entry.PreflightError):entry.validate_host('windows')
            entry.validate_host('windows',wine=Path('/explicit/wine'))


if __name__ == '__main__': unittest.main()
