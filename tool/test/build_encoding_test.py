"""Real pipe/launcher fixtures only: no client, native library or installer build."""
import ast
import importlib.util
import json
import io
import tarfile
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
DART = shutil.which('dart')
if DART:
    runtime = Path(DART).resolve().parent / ('cache/dart-sdk/bin/dart.exe' if os.name == 'nt' else 'cache/dart-sdk/bin/dart')
    if runtime.is_file(): DART = str(runtime)


def run(argv, **kwargs):
    return subprocess.run(argv if isinstance(argv, str) else [str(x) for x in argv], capture_output=True, text=True,
                          encoding='utf-8', errors='replace', timeout=90, **kwargs)


@unittest.skipUnless(DART, 'Dart SDK required')
class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xfl-中文 ! & ()-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'tool').mkdir()
        shutil.copyfile(ROOT/'tool/build_tool_runner.dart', self.root/'tool/build_tool_runner.dart')
        (self.root/'pubspec.yaml').write_text('name: fixture\n', encoding='utf-8')
        (self.root/'core').mkdir()
        self.env = {**os.environ, 'FLUTTER_ROOT':str(Path(DART).parents[4]),
                    'CARGOKIT_TOOL_TEMP_DIR':str(self.root/'cargo temp'), 'PROJECT_DIR':str(self.root),
                    'DART_SUPPRESS_ANALYTICS':'true', 'CI':'true'}
        for directory in ('plugins/setup/buildkit', 'plugins/rust_api/cargokit'):
            target = self.root/directory
            (target/'build_tool/lib').mkdir(parents=True)
            for name in ('bootstrap.dart','run_build_tool.sh','run_build_tool.cmd'):
                shutil.copyfile(ROOT/directory/name, target/name)
            (target/'build_tool/pubspec.yaml').write_text(
                'name: build_tool\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n',encoding='utf-8')
            (target/'build_tool/lib/build_tool.dart').write_text('''import 'dart:io';
import 'dart:convert';
void runMain(List<String> args) {
  stdout.encoding = utf8;
  print('FIXTURE_ARGS=' + jsonEncode(args));
  final count = File('runs');
  final n = count.existsSync() ? int.parse(count.readAsStringSync()) : 0;
  count.writeAsStringSync('${n+1}');
  exitCode = Platform.environment['ONCE_253'] == '1' && n == 0 ? 253 :
    int.parse(Platform.environment['CHILD_EXIT'] ?? '0');
}
''',encoding='utf-8')

    def launch(self, kind='cargo', extra=None, symlink=False):
        directory = self.root/('plugins/setup/buildkit' if kind=='setup' else 'plugins/rust_api/cargokit')
        if symlink:
            alias=self.root/'ephemeral/.plugin_symlinks/tool'
            alias.parent.mkdir(parents=True,exist_ok=True)
            alias.symlink_to(directory, target_is_directory=True)
            directory=alias
        args=['中文 value', 'literal!&()', 'a"b']
        env={**self.env, **(extra or {})}
        if os.name=='nt':
            # cmd.exe's quote syntax cannot represent a raw quote argument here;
            # YAML path escaping is tested via JSON below on all platforms.
            args=args[:2]
            command = ' '.join(chr(34)+value+chr(34) for value in [str(directory/'run_build_tool.cmd'), *args])
            return run('cmd.exe /d /v:off /s /c '+chr(34)+command+chr(34),cwd=self.root,env=env)
        return run(['bash',directory/'run_build_tool.sh',*args],cwd=self.root,env=env)

    def test_both_launchers_real_child_utf8_paths_arguments_and_cache(self):
        for kind in ('setup','cargo'):
            with self.subTest(kind=kind):
                first=self.launch(kind)
                self.assertEqual(first.returncode,0,first.stdout+first.stderr)
                work=self.root/('build/setup_build_tool' if kind=='setup' else 'cargo temp')
                spec=json.loads((work/'pubspec.yaml').read_text(encoding='utf-8'))
                self.assertTrue(Path(spec['dependencies']['build_tool']['path']).is_dir())
                self.assertIn('中文',spec['dependencies']['build_tool']['path'])
                row=next(line for line in first.stdout.splitlines() if line.startswith('FIXTURE_ARGS='))
                args=json.loads(row.split('=',1)[1]);self.assertEqual(args[:2],['中文 value','literal!&()'])
                if kind=='setup':self.assertEqual(args[-2:],['--root-dir',str(self.root)])
                kernel=work/'bin/build_tool_runner.dill';before=kernel.stat().st_mtime_ns
                second=self.launch(kind);self.assertEqual(second.returncode,0,second.stderr)
                self.assertEqual(kernel.stat().st_mtime_ns,before)
                source=Path(spec['dependencies']['build_tool']['path'])/'lib/build_tool.dart'
                source.write_text(source.read_text(encoding='utf-8')+'\n// changed\n',encoding='utf-8')
                third=self.launch(kind);self.assertEqual(third.returncode,0,third.stderr)
                self.assertNotEqual(kernel.stat().st_mtime_ns,before)

    @unittest.skipIf(os.name=='nt','POSIX symlink fixture; Windows provider tested separately')
    def test_flutter_plugin_symlink_launch(self):
        result=self.launch(symlink=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_invalid_snapshot_retries_once_and_preserves_real_exit(self):
        result=self.launch(extra={'ONCE_253':'1','CHILD_EXIT':'7'})
        self.assertEqual(result.returncode,7,result.stdout+result.stderr)
        self.assertEqual((self.root/'cargo temp/runs').read_text(encoding='utf-8'),'2')

    def test_dependency_and_compile_failure_never_runs_previous_kernel(self):
        self.assertEqual(self.launch().returncode,0)
        work=self.root/'cargo temp';pkg=self.root/'plugins/rust_api/cargokit/build_tool'
        original=(pkg/'pubspec.yaml').read_text(encoding='utf-8')
        (pkg/'pubspec.yaml').write_text('name: [invalid\n',encoding='utf-8')
        result=self.launch();self.assertNotEqual(result.returncode,0)
        self.assertFalse((work/'bin/build_tool_runner.dill').exists())
        self.assertEqual((work/'runs').read_text(encoding='utf-8'),'1')
        (pkg/'pubspec.yaml').write_text(original,encoding='utf-8')
        (pkg/'lib/build_tool.dart').write_text('invalid syntax !',encoding='utf-8')
        result=self.launch();self.assertNotEqual(result.returncode,0)
        self.assertEqual((work/'runs').read_text(encoding='utf-8'),'1')
        self.assertFalse((work/'.bootstrap-inputs.json').exists())


@unittest.skipUnless(DART and (ROOT/'.dart_tool/package_config.json').is_file(), 'Resolved Dart dependencies required')
class PipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(prefix='xfl-pipes-中文-');cls.addClassCleanup(cls.tmp.cleanup)
        cls.root=Path(cls.tmp.name)
        spec=importlib.util.spec_from_file_location('encoding_packager',ROOT/'tool/prepare_linux_packager.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        module.prepare(ROOT/'plugins/flutter_distributor',cls.root/'packager')
        cls.child=cls.root/'child.dart'
        cls.child.write_text('''import 'dart:io';
Future<void> main(List<String> args) async {
  stdout.add([0xe4]); await stdout.flush();
  await Future<void>.delayed(Duration(milliseconds: 80));
  stdout.add([0xb8,0xad,0xe6,0x96,0x87,13,10]);
  stderr.add([0xff,0xd6,0xd0]); await stderr.flush();
  stdout.write('tail-no-newline');
  stderr.write('last-error');
  exitCode=int.parse(args[0]);
}
''',encoding='utf-8')

    def test_base_active_distributor_and_buildkit_drain_split_and_malformed_logs(self):
        base=self.root/'packager/packages/shell_executor/lib/src/shell_executor.dart'
        active=self.root/'packager/packages/flutter_distributor/lib/src/utils/default_shell_executor.dart'
        active_class=active.read_text(encoding='utf-8').split('class DefaultShellExecutor',1)[1]
        for executor in ('base','active','buildkit','cargo','sync'):
            for code in (0,7):
                with self.subTest(executor=executor,code=code):
                    source="import 'dart:io';\nimport 'dart:convert';\n"
                    if executor in ('buildkit','cargo'):
                        source+=f"import '{(ROOT/'plugins/setup/buildkit/build_tool/lib/src/util.dart').as_uri()}';\n"
                        source+="import 'package:logging/logging.dart';\n"
                        if executor=='cargo':
                            source=source.replace('plugins/setup/buildkit/build_tool', 'plugins/rust_api/cargokit/build_tool')
                        method="Logger.root.onRecord.listen((r) => stdout.writeln(r.message)); await runCommandStream(Platform.resolvedExecutable,args);"
                        if executor=='cargo': method="final r=runCommand(Platform.resolvedExecutable,args); stdout.write(r.stdout); stderr.write(r.stderr); exitCode=r.exitCode;"
                    else:
                        source+=f"import '{base.as_uri()}';\n"
                        if executor=='active':
                            source+='''extension Colors on String { String brightBlack()=>this; String brightRed()=>this; }
class Log { void info(Object? message) {} }
final logger=Log();
class DefaultShellExecutor'''+active_class
                        method=f"final r=await {'DefaultShellExecutor' if executor=='active' else 'ShellExecutor'}().exec(Platform.resolvedExecutable,args); stdout.writeln('RESULT=${{r.exitCode}}:${{r.stdout}}:${{r.stderr}}'); exitCode=r.exitCode;"
                    if executor=='sync':
                        method="final r=ShellExecutor().execSync(Platform.resolvedExecutable,args); stdout.write(r.stdout); stderr.write(r.stderr); exitCode=r.exitCode;"
                    source+='Future<void> main(List<String> args) async { stdout.encoding=utf8; stderr.encoding=utf8; try {'+method+"} catch (e) { stderr.writeln(e); exitCode=7; } }"
                    script=self.root/'probe.dart';script.write_text(source,encoding='utf-8')
                    result=run([DART,'--disable-dart-dev','--packages='+str(ROOT/'.dart_tool/package_config.json'),script,self.child,str(code)])
                    self.assertEqual(result.returncode,code,result.stdout+result.stderr)
                    self.assertIn('中文',result.stdout+result.stderr);self.assertIn('tail-no-newline',result.stdout+result.stderr)
                    self.assertIn('last-error',result.stdout+result.stderr)
                    self.assertNotIn('FormatException',result.stderr)

    def test_machine_stdout_rejects_invalid_utf8(self):
        child=self.root/'invalid.dart'
        child.write_text("import 'dart:io'; void main() { stdout.add([255]); }",encoding='utf-8')
        for owner,uri,method in [
            ('executor',(self.root/'packager/packages/shell_executor/lib/src/shell_executor.dart').as_uri(), 'ShellExecutor().execSync'),
            ('cargo',(ROOT/'plugins/rust_api/cargokit/build_tool/lib/src/util.dart').as_uri(), 'runCommand')]:
            script=self.root/'strict.dart'
            script.write_text("import 'dart:io'; import '"+uri+"'; void main(List<String> args) { "
                "try { "+method+"(Platform.resolvedExecutable,args); exitCode=9; } "
                "on FormatException { stdout.write('REJECTED'); } }",encoding='utf-8')
            result=run([DART,'--disable-dart-dev','--packages='+str(ROOT/'.dart_tool/package_config.json'),script,child])
            self.assertEqual(result.returncode,0,owner+result.stderr)
            self.assertEqual(result.stdout,'REJECTED')

    def test_old_chunk_decoder_negative_control(self):
        script=self.root/'old.dart';script.write_text("import 'dart:convert'; void main() { utf8.decoder.convert([0xe4]); }",encoding='utf-8')
        result=run([DART,'--disable-dart-dev',script]);self.assertNotEqual(result.returncode,0)
        self.assertIn('FormatException',result.stderr)


class FileEncodingTests(unittest.TestCase):
    def test_production_python_path_text_io_declares_utf8(self):
        for path in (ROOT/'tool').glob('*.py'):
            for node in ast.walk(ast.parse(path.read_text(encoding='utf-8'))):
                if isinstance(node,ast.Call) and isinstance(node.func,ast.Attribute) and node.func.attr in ('read_text','write_text'):
                    self.assertTrue(any(k.arg=='encoding' for k in node.keywords),f'{path.name}:{node.lineno}')

    def test_real_git_checkout_preserves_patch_and_shell_bytes(self):
        with tempfile.TemporaryDirectory(prefix='xfl-checkout-') as temp:
            root=Path(temp)
            paths=['.gitattributes','tool/patches/flutter_distributor_appimage.patch',
                   'plugins/setup/buildkit/run_build_tool.sh','plugins/rust_api/cargokit/run_build_tool.sh']
            for name in paths:
                target=root/name;target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(ROOT/name,target)
            for args in (['init','--quiet'],['add','--',*paths]):
                result=run(['git',*args],cwd=root);self.assertEqual(result.returncode,0,result.stderr)
            for mode in ('false','input','true'):
                dest=root/('checkout-'+mode);dest.mkdir()
                result=run(['git','-c','core.autocrlf='+mode,'checkout-index','--all',
                            '--prefix='+dest.as_posix()+'/'],cwd=root)
                self.assertEqual(result.returncode,0,result.stderr)
                for name in paths[1:]:self.assertEqual((dest/name).read_bytes(),(ROOT/name).read_bytes())

    def test_windows_export_needs_no_symlink_privilege(self):
        spec=importlib.util.spec_from_file_location('export_packager',ROOT/'tool/prepare_linux_packager.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='xfl-export-') as temp:
            root=Path(temp)
            archive=module.git(ROOT/'plugins/flutter_distributor','archive',module.PINNED_REVISION,'packages','LICENSE','README.md')
            with mock.patch.object(Path,'symlink_to',side_effect=AssertionError('symlink privilege required')):
                module.export_tool_archive(archive,root,materialize_links=True)
            self.assertEqual((root/'packages/flutter_distributor/README.md').read_bytes(),(root/'README.md').read_bytes())
            module.verify_hashes(root,0)

    def test_windows_archive_rejects_escape_drive_and_stream_paths(self):
        spec=importlib.util.spec_from_file_location('unsafe_packager',ROOT/'tool/prepare_linux_packager.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        for name,target in [('C:/escape',None),('file:stream',None),('link','../../escape'),('link','missing')]:
            with self.subTest(name=name,target=target), tempfile.TemporaryDirectory() as temp:
                data=io.BytesIO()
                with tarfile.open(fileobj=data,mode='w') as archive:
                    member=tarfile.TarInfo(name)
                    if target:
                        member.type=tarfile.SYMTYPE;member.linkname=target
                    archive.addfile(member)
                with self.assertRaisesRegex(RuntimeError,'Unsafe tool archive'):
                    module.export_tool_archive(data.getvalue(),Path(temp),materialize_links=True)

    def test_old_cp1252_chinese_path_negative_control(self):
        with self.assertRaises(UnicodeEncodeError): '中文 repo/helper.cmake'.encode('cp1252')


if __name__=='__main__':
    if not DART or not (ROOT/'.dart_tool/package_config.json').is_file():
        raise SystemExit('Dart SDK and resolved client dependencies are required')
    unittest.main()
