"""Semantic release-tool boundaries; no SDK, Flutter, network or app build."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]


def commands(text):
    for raw in text.replace('\\\r\n','').replace('\\\n','').splitlines():
        line=raw.strip()
        if line.startswith('run: '): line=line[5:]
        if not line or line.startswith('#'): continue
        try: argv=shlex.split(line,comments=True)
        except ValueError: continue  # YAML headings/other steps are not shell commands.
        if argv and argv[0] in {'python','python3','dart','flutter'}: yield argv


def validate_download_and_codegen(text):
    downloads=[];generators=[]
    for argv in commands(text):
        if argv[:3] == ['dart','run','build_runner']:
            raise AssertionError('legacy codegen entry')
        if len(argv)<2:continue
        tool=argv[1].replace('\\','/').rsplit('/',1)[-1]
        if tool=='pub_get_retry.py':
            if argv[0] not in {'python','python3'}:raise AssertionError('Python retry entry required')
            values={};index=2
            while index<len(argv):
                flag=argv[index]
                if flag=='--enforce-lockfile':
                    if flag in values:raise AssertionError('duplicate retry option')
                    values[flag]=True;index+=1;continue
                if flag not in {'--tool','--report'} or flag in values or index+1>=len(argv):
                    raise AssertionError('retry must only wrap pub get')
                values[flag]=argv[index+1];index+=2
            if (values.get('--tool') not in {'dart','flutter'} or not values.get('--report')
                    or values.get('--enforce-lockfile') is not True):
                raise AssertionError('strict dependency download required')
            downloads.append(values['--tool'])
        elif tool=='dart_package.py' and 'build_runner' in argv:
            if argv[0] not in {'python','python3'}:raise AssertionError('Python tool entry required')
            if argv[2:]!=['build_runner','build']:raise AssertionError('codegen must run build without bypasses')
            generators.append(argv)
    if set(downloads)!={'dart','flutter'} or len(generators)<2:
        raise AssertionError('SDK/client download or generation omitted')


class WorkflowEntryContracts(unittest.TestCase):
    def test_current_workflows_keep_downloads_and_generation_separate(self):
        for name in ('release-package.yml','xboard-ci.yml'):
            validate_download_and_codegen((ROOT/'.github/workflows'/name).read_text(encoding='utf-8'))

    def test_semantics_accept_whitespace_quotes_crlf_and_option_order(self):
        commands_text='''python3 "$GITHUB_WORKSPACE/tool/pub_get_retry.py" --report sdk.json --enforce-lockfile --tool dart
python tool/pub_get_retry.py --tool flutter --enforce-lockfile --report client.json
python "$GITHUB_WORKSPACE/tool/dart_package.py" build_runner build
python3 "tool/dart_package.py" build_runner build # client
'''
        for text in (commands_text,commands_text.replace('\n','\r\n'),commands_text.replace(' --report client.json',' \\\n --report client.json')):
            validate_download_and_codegen(text)

    def test_legacy_or_retry_wrapped_build_and_missing_stages_are_rejected(self):
        base=(ROOT/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        marker='python "$GITHUB_WORKSPACE/tool/dart_package.py" build_runner build'
        self.assertIn(marker,base)
        cases=[base.replace(marker,'dart run build_runner build'),
               base.replace(marker,'python tool/pub_get_retry.py --tool dart --enforce-lockfile --report x -- build_runner build'),
               base.replace(marker,'# '+marker),
               base.replace(marker,marker+' || true'),
               base.replace('--enforce-lockfile','')]
        for text in cases:
            with self.subTest(case=cases.index(text)),self.assertRaises(AssertionError):validate_download_and_codegen(text)

    def test_local_desktop_declares_python3_for_pure_tools(self):
        text=(ROOT/'scripts/package_desktop_local.sh').read_text(encoding='utf-8')
        selected=[argv for argv in commands(text) if len(argv)>1 and argv[1].replace('\\','/').rsplit('/',1)[-1]=='dart_package.py']
        self.assertTrue(selected)
        self.assertTrue(all(argv[0]=='python3' for argv in selected))

    @unittest.skipIf(os.name=='nt','Python3-only POSIX PATH fixture; Windows source contract still checked')
    def test_actual_icon_command_with_only_python3_and_both_brands(self):
        line=next(line for line in (ROOT/'scripts/package_desktop_local.sh').read_text(encoding='utf-8').splitlines() if line.startswith('python3 tool/dart_package.py flutter_launcher_icons'))
        with tempfile.TemporaryDirectory(prefix='desktop-python3-') as directory:
            root=Path(directory);binary=root/'bin';binary.mkdir();(binary/'python3').symlink_to(sys.executable)
            (root/'tool').mkdir();script=root/'tool/dart_package.py'
            script.write_text('import json,os,sys\nprint(json.dumps([os.environ["FLAVOR"],sys.argv[1:]]))\nsys.exit(int(os.environ["FIXTURE_EXIT"]))\n',encoding='utf-8')
            for flavor in ('brand_a','brand_b'):
                env={'PATH':str(binary),'FLAVOR':flavor,'FIXTURE_EXIT':'0'}
                result=subprocess.run(['/bin/bash','-c',line],cwd=root,env=env,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(json.loads(result.stdout),[flavor,['flutter_launcher_icons','-f','flutter_launcher_icons.yaml']])
                failed=subprocess.run(['/bin/bash','-c','set -e\n'+line+'\nprintf unexpected-success'],cwd=root,env={**env,'FIXTURE_EXIT':'23'},capture_output=True,text=True)
                self.assertEqual(failed.returncode,23);self.assertNotIn('unexpected-success',failed.stdout)
                old=subprocess.run(['/bin/bash','-c',line.replace('python3 ','python ',1)],cwd=root,env=env,capture_output=True,text=True)
                self.assertEqual(old.returncode,127)


if __name__=='__main__':unittest.main()
