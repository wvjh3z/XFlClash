"""Launcher resolution and opt-in real Flutter/rustup preflight, never app build."""
from contextlib import chdir
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tool'))
import flutter_check
from prepare_native_build import resolve_rustup

HOOKS='hooks:\n  user_defines:\n    setup:\n      build_assets: true\n    rust_api:\n      build_assets: true\n'


class LauncherTests(unittest.TestCase):
    def test_windows_uses_executable_and_keeps_literal_unicode_arguments(self):
        with tempfile.TemporaryDirectory(prefix='sdk 中文 & ') as tmp:
            root=Path(tmp)
            dart=root/'bin/cache/dart-sdk/bin/dart.exe';dart.parent.mkdir(parents=True);dart.touch()
            snapshot=root/'bin/cache/flutter_tools.snapshot';snapshot.touch()
            args=['--no-pub','test/中文 空格_test.dart','--dart-define=VALUE=a&b%X%!']
            self.assertEqual(flutter_check.command(args,environment={'FLUTTER_ROOT':tmp},windows=True),[str(dart),str(snapshot),'test',*args])
            snapshot.unlink()
            with self.assertRaisesRegex(RuntimeError,'snapshot missing'):
                flutter_check.command(args,environment={'FLUTTER_ROOT':tmp},windows=True)

    def test_missing_flutter_fails_without_modifying_pubspec(self):
        with tempfile.TemporaryDirectory() as tmp,chdir(tmp):
            path=Path('pubspec.yaml');path.write_text(HOOKS)
            before=path.read_bytes()
            with mock.patch.object(flutter_check,'command',side_effect=RuntimeError('missing')):
                self.assertEqual(flutter_check.main(['test.dart']),1)
            self.assertEqual(path.read_bytes(),before)

    def test_exit_and_launch_failure_restore_lf_crlf(self):
        for newline in ['\n','\r\n']:
            for failure in [False,True]:
                with tempfile.TemporaryDirectory() as tmp,chdir(tmp):
                    path=Path('pubspec.yaml');original=HOOKS.replace('\n',newline).encode();path.write_bytes(original)
                    def run(argv):
                        self.assertEqual(path.read_bytes().count(b'build_assets: false'),2)
                        if failure:raise OSError('controlled launch failure')
                        return subprocess.CompletedProcess(argv,37)
                    with mock.patch.object(flutter_check,'command',return_value=['fake','test']),mock.patch.object(flutter_check.subprocess,'run',side_effect=run):
                        self.assertEqual(flutter_check.main(['test.dart']),1 if failure else 37)
                    self.assertEqual(path.read_bytes(),original)

    def test_rustup_uses_path_not_cargo_home_and_never_default_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);external=root/'external';external.mkdir()
            binary=external/('rustup.exe' if os.name=='nt' else 'rustup');binary.touch();binary.chmod(0o755)
            environment={'PATH':str(external),'CARGO_HOME':str(root/'empty-cargo')}
            self.assertEqual(Path(resolve_rustup(environment)),binary.absolute())
            with self.assertRaisesRegex(RuntimeError,'rustup unavailable'):
                resolve_rustup({'PATH':'','CARGO_HOME':str(external)})


@unittest.skipUnless(os.environ.get('XFLCLASH_REAL_LAUNCHER_TEST')=='1','Requires explicitly prepared remote/CI toolchain')
class RealLauncherTests(unittest.TestCase):
    def test_formal_flutter_check_runs_and_restores_on_pass_and_failure(self):
        with tempfile.TemporaryDirectory(prefix='flutter-check-中文 空格-') as tmp:
            root=Path(tmp);(root/'test').mkdir()
            pubspec=root/'pubspec.yaml'
            pubspec.write_text('name: launcher_fixture\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n'+HOOKS,encoding='utf-8')
            cli=flutter_check.command([])[:-1]
            pub=subprocess.run([*cli,'pub','get','--offline'],cwd=root,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=120)
            self.assertEqual(pub.returncode,0,pub.stdout+pub.stderr)
            original=pubspec.read_bytes()
            test=root/'test/中文 空格 & 字面_test.dart'
            for succeed in [True,False]:
                test.write_text('import "package:flutter_test/flutter_test.dart";\nvoid main(){test("launcher",(){expect(const String.fromEnvironment("LITERAL"),"中文 & % !");expect(1,'+('1' if succeed else '2')+');});}\n',encoding='utf-8')
                run=subprocess.run([sys.executable,str(ROOT/'tool/flutter_check.py'),'--no-pub','--dart-define=LITERAL=中文 & % !',str(test)],cwd=root,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=180)
                self.assertEqual(run.returncode==0,succeed,run.stdout+run.stderr)
                if not succeed:self.assertIn('Expected: <2>',run.stdout+run.stderr)
                self.assertEqual(pubspec.read_bytes(),original)

    def test_real_rustup_outside_cargo_home_keeps_fixed_version(self):
        pin=json.loads((ROOT/'tool/native_toolchain.json').read_text())['rust']
        actual=resolve_rustup()
        with tempfile.TemporaryDirectory(prefix='rustup-external-') as tmp:
            root=Path(tmp);external=root/'external';external.mkdir()
            binary=external/Path(actual).name;shutil.copyfile(actual,binary);binary.chmod(0o755)
            environment={**os.environ,'PATH':str(external)+os.pathsep+os.environ.get('PATH',''),'CARGO_HOME':str(root/'empty-cargo')}
            environment.pop('RUSTUP_TOOLCHAIN',None)
            resolved=resolve_rustup(environment)
            self.assertEqual(Path(resolved),binary)
            good=subprocess.run([resolved,'run',pin,'rustc','--version'],env=environment,capture_output=True,text=True,timeout=60)
            self.assertEqual(good.returncode,0,good.stderr)
            self.assertTrue(good.stdout.startswith('rustc '+pin+' '),good.stdout)
            bad=subprocess.run([resolved,'run','xflclash-uninstalled-control','rustc','--version'],env=environment,capture_output=True,text=True,timeout=60)
            self.assertNotEqual(bad.returncode,0)


if __name__=='__main__':unittest.main()
