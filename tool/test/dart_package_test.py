"""Real VM tool entry: no dart-run native hook dispatch and no config rewriting."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tool'))
import dart_package


class DartPackageTests(unittest.TestCase):
    def test_resolved_entry_preserves_unicode_args_and_never_calls_dart_run(self):
        with tempfile.TemporaryDirectory(prefix='dart-tool-中文-') as folder:
            root=Path(folder);graph=root/'.dart_tool/package_config.json';graph.parent.mkdir()
            package=root/'package space';(package/'bin').mkdir(parents=True)
            source=package/'bin/build_runner.dart';source.write_text('fixture',encoding='utf-8')
            flutter=root/'flutter';dart=flutter/('bin/cache/dart-sdk/bin/dart.exe' if os.name=='nt' else 'bin/cache/dart-sdk/bin/dart');dart.parent.mkdir(parents=True);dart.touch()
            graph.write_text(json.dumps({'packages':[{'name':'build_runner','rootUri':package.as_uri()}]}),encoding='utf-8')
            argv=dart_package.command('build_runner',['build','中文参数'],root=root,flutter=flutter)
            self.assertEqual(argv,[str(dart),'--packages='+str(graph),str(source),'build','中文参数'])
            source.unlink()
            with self.assertRaises(ValueError):dart_package.command('build_runner',[],root=root,flutter=flutter)
            with self.assertRaises(ValueError):dart_package.command('arbitrary',[],root=root,flutter=flutter)

    def test_real_vm_does_not_execute_a_failing_native_hook(self):
        flutter=Path(os.environ['FLUTTER_ROOT'])
        with tempfile.TemporaryDirectory(prefix='dart-no-hooks-') as folder:
            root=Path(folder);graph=root/'.dart_tool/package_config.json';graph.parent.mkdir()
            package=root/'tool';(package/'bin').mkdir(parents=True);(root/'hook').mkdir()
            (root/'pubspec.yaml').write_text('name: fixture\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  build_runner:\n    path: tool\n  native_fixture:\n    path: native\n',encoding='utf-8')
            (package/'pubspec.yaml').write_text('name: build_runner\nversion: 1.0.0\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\n',encoding='utf-8')
            native=root/'native';(native/'hook').mkdir(parents=True)
            (native/'pubspec.yaml').write_text('name: native_fixture\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\n',encoding='utf-8')
            (native/'hook/build.dart').write_text('void main(){throw StateError("native-hook-negative-control");}',encoding='utf-8')
            source=package/'bin/build_runner.dart';source.write_text('import "dart:convert";void main(List<String> args){print(jsonEncode(args));}',encoding='utf-8')
            dart=flutter/('bin/cache/dart-sdk/bin/dart.exe' if os.name=='nt' else 'bin/cache/dart-sdk/bin/dart')
            pub=subprocess.run([str(dart),'pub','get','--offline'],cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=30)
            self.assertEqual(pub.returncode,0,pub.stderr)
            before=(root/'pubspec.yaml').read_bytes()
            result=subprocess.run(dart_package.command('build_runner',['中文','two words'],root=root,flutter=flutter),cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout),['中文','two words'])
            self.assertEqual((root/'pubspec.yaml').read_bytes(),before)
            self.assertFalse((root/'.dart_tool/hooks_runner').exists())
            # The former production entry really reaches the deliberately
            # failing hook; the positive case above did not merely omit it.
            shutil.copyfile(source,root/'main.dart')
            negative=subprocess.run([str(dart),'run','main.dart','中文'],cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=60)
            self.assertNotEqual(negative.returncode,0)
            self.assertIn('native-hook-negative-control',negative.stdout+negative.stderr)



if __name__=='__main__':unittest.main()
