#!/usr/bin/env python3
"""Number inputs and real temporary-Git publication races; no builds/network."""
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_build_number as numbers
try:
    from .sentry_release_workflow_test import step_script
except ImportError:
    from sentry_release_workflow_test import step_script


class NumberTests(unittest.TestCase):
    def test_empty_uses_counter_and_manual_equal_or_larger_is_allowed(self):
        self.assertEqual(numbers.resolve("21", ""), 21)
        self.assertEqual(numbers.resolve("21", "21"), 21)
        self.assertEqual(numbers.resolve("21", "50"), 50)
        self.assertEqual(numbers.resolve("1", ""), 1)

    def test_invalid_and_lower_inputs_fail_before_build(self):
        for value in ("0", "-1", "20", "21.0", " 22", "22 ", "0022", "２２", "22\n",
                      "$(touch unexpected)", "22;exit 0", str(numbers.MAX_BUILD_NUMBER + 1)):
            with self.subTest(value=value), self.assertRaises(numbers.BuildNumberError):
                numbers.resolve("21", value)
        for value in ("", "bad", "0", "21\n"):
            with self.subTest(counter=value), self.assertRaises(numbers.BuildNumberError):
                numbers.resolve(value)

    def test_next_counter_tracks_actual_build_and_never_goes_back(self):
        self.assertEqual(numbers.next_counter("21", "21"), 22)
        self.assertEqual(numbers.next_counter("21", "50"), 51)
        self.assertEqual(numbers.next_counter("60", "50"), 60)
        self.assertEqual(numbers.next_counter("51", "50"), 51)
        exhausted = str(numbers.next_counter(str(numbers.MAX_BUILD_NUMBER), str(numbers.MAX_BUILD_NUMBER)))
        with self.assertRaises(numbers.BuildNumberError):
            numbers.resolve(exhausted)

    def test_cli_outputs_actual_number_without_advancing_source_counter(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            counter = root / "scripts/build_number.brand_a.txt"
            counter.write_text("21\n")
            output, summary = root / "output", root / "summary"
            with mock.patch.dict(os.environ, {"REQUESTED_BUILD_NUMBER": "50", "GITHUB_OUTPUT": str(output),
                                              "GITHUB_STEP_SUMMARY": str(summary)}, clear=True), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(numbers.main(["resolve", "--flavor", "brand_a", "--project-root", str(root)]), 0)
            self.assertEqual(output.read_text(), "build_number=50\n")
            self.assertIn("Build 50", summary.read_text())
            self.assertIn("manual input", summary.read_text())
            self.assertEqual(counter.read_text(), "21\n")
            with mock.patch.dict(os.environ, {"RESOLVED_BUILD_NUMBER": "50"}, clear=True), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(numbers.main(["advance", "--flavor", "brand_a", "--project-root", str(root)]), 0)
            self.assertEqual(counter.read_text(), "51\n")

    def test_cli_rejects_missing_counter_and_never_reflects_untrusted_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(numbers.main(["resolve", "--flavor", "brand_b", "--project-root", str(root)]), 1)
            self.assertNotIn(str(root), errors.getvalue())
            (root / "scripts").mkdir()
            (root / "scripts/build_number.brand_b.txt").write_text("1\n")
            with mock.patch.dict(os.environ, {"REQUESTED_BUILD_NUMBER": "fake-private-input"}, clear=True), \
                 contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(numbers.main(["resolve", "--flavor", "brand_b", "--project-root", str(root)]), 1)
            self.assertNotIn("fake-private-input", errors.getvalue())

    @unittest.skipUnless(shutil.which("git"), "Pinned source validation needs Git")
    def test_cli_checks_pinned_source_before_writing_number_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            counter = root / "scripts/build_number.brand_a.txt"
            counter.write_text("21\n")
            for arguments in (["init", "--initial-branch=main"], ["add", "."],
                              ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                               "commit", "-m", "fixture"]):
                subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True)
            sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            output, summary = root / "output", root / "summary"
            for expected_sha, ref, expected_code in (("a" * 40, "refs/heads/main", 1),
                                                       (sha, "invalid-ref", 1),
                                                       (sha, "refs/heads/main", 0)):
                with self.subTest(source=expected_sha, ref=ref):
                    env = {"BUILD_SOURCE_SHA": expected_sha, "BUILD_SOURCE_REF": ref,
                           "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)}
                    with mock.patch.dict(os.environ, env, clear=True), \
                         contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                        self.assertEqual(numbers.main(["resolve", "--flavor", "brand_a",
                                                       "--project-root", str(root)]), expected_code)
                    if expected_code:
                        self.assertFalse(output.exists())
                        self.assertFalse(summary.exists())
                    else:
                        self.assertEqual(output.read_text(), "build_number=21\n")
                        self.assertIn(sha, summary.read_text())
                        self.assertIn("source snapshot counter", summary.read_text())
                    self.assertEqual(counter.read_text(), "21\n")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash") and shutil.which("git"),
                     "Publication runs on the Linux bump job")
class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.script = step_script('Increment build_number for flavor')
        self.temp = tempfile.TemporaryDirectory(prefix='number-branch-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.origin, self.seed, self.worker, self.other = [self.root/n for n in ('origin.git','seed','worker','other')]
        self.real_git = shutil.which('git')
        self.env = {'PATH':os.environ['PATH'],'HOME':str(self.root),'GIT_CONFIG_NOSYSTEM':'1',
                    'GIT_CONFIG_GLOBAL':os.devnull,'GIT_TERMINAL_PROMPT':'0',
                    'GIT_AUTHOR_NAME':'fixture','GIT_AUTHOR_EMAIL':'fixture@example.invalid',
                    'GIT_COMMITTER_NAME':'fixture','GIT_COMMITTER_EMAIL':'fixture@example.invalid'}
        self.git('init','--bare','--initial-branch=main',str(self.origin))
        self.git('init','--initial-branch=main',str(self.seed))
        (self.seed/'scripts').mkdir();(self.seed/'tool').mkdir()
        for brand,value in [('brand_a',21),('brand_b',7)]:
            (self.seed/f'scripts/build_number.{brand}.txt').write_text(str(value)+'\n')
        shutil.copy2(Path(numbers.__file__),self.seed/'tool/release_build_number.py')
        self.git('add','.',cwd=self.seed);self.git('commit','-m','seed',cwd=self.seed)
        self.git('remote','add','origin',str(self.origin),cwd=self.seed)
        self.git('push','origin','main',cwd=self.seed)
        self.branch='upgrade/flclash-v0.9.1';self.ref='refs/heads/'+self.branch
        self.git('checkout','-b',self.branch,cwd=self.seed)
        (self.seed/'upgrade-only.txt').write_text('upgrade source')
        self.git('add','.',cwd=self.seed);self.git('commit','-m','upgrade',cwd=self.seed)
        self.git('push','origin',self.branch,cwd=self.seed)
        self.source=self.git('rev-parse','HEAD',cwd=self.seed).strip()
        self.main=self.tip('main')
        self.git('clone',str(self.origin),str(self.worker))
        self.git('clone','--branch',self.branch,str(self.origin),str(self.other))
        self.git('checkout','--detach',self.source,cwd=self.worker)
        (self.root/'runner-temp').mkdir()
        self.run_env={**self.env,'FLAVOR':'brand_a','RESOLVED_BUILD_NUMBER':'50',
                      'BUILD_SOURCE_REF':self.ref,'BUILD_SOURCE_SHA':self.source,
                      'RUNNER_TEMP':str(self.root/'runner-temp')}

    def git(self,*args,cwd=None):
        return subprocess.check_output([self.real_git,*args],cwd=cwd,env=self.env,
                                        stderr=subprocess.STDOUT,text=True,timeout=15)

    def tip(self,ref):
        return self.git('rev-parse',ref,cwd=self.origin).strip()

    def counter(self,ref,brand):
        return int(self.git('show',f'{ref}:scripts/build_number.{brand}.txt',cwd=self.origin))

    def invoke(self,**env):
        return subprocess.run(['bash','-c',self.script],cwd=self.worker,env={**self.run_env,**env},
                              capture_output=True,text=True,timeout=30)

    def assert_ok(self,result):
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def race_environment(self,brand='brand_a',value=60,mode='update'):
        binary=self.root/'bin';binary.mkdir(exist_ok=True)
        wrapper=binary/'git'
        wrapper.write_text('#!'+sys.executable+'\n'+'''
import os,pathlib,subprocess,sys
args=sys.argv[1:];real=os.environ['REAL_GIT'];mark=pathlib.Path(os.environ['RACE_MARKER'])
if args and args[0]=='push' and any(a.startswith('--force-with-lease=') for a in args) and not mark.exists():
    mark.write_text('race')
    other=pathlib.Path(os.environ['OTHER']);ref=os.environ['SOURCE_REF']
    def git(*a):subprocess.run([real,*a],cwd=other,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if os.environ['MODE']=='delete':git('push','origin',':'+ref)
    else:
        (other/('scripts/build_number.'+os.environ['OTHER_BRAND']+'.txt')).write_text(os.environ['OTHER_NUMBER']+'\\n')
        (other/'independent-change.txt').write_text('must survive')
        (other/'tool/release_build_number.py').write_text('raise SystemExit(93)\\n')
        git('add','.');git('commit','-m','race');git('push','origin',ref)
raise SystemExit(subprocess.run([real,*args]).returncode)
''')
        wrapper.chmod(0o755)
        return {'PATH':str(binary)+os.pathsep+self.env['PATH'],'REAL_GIT':self.real_git,
                'RACE_MARKER':str(self.root/'race'),'OTHER':str(self.other),'SOURCE_REF':self.ref,
                'OTHER_BRAND':brand,'OTHER_NUMBER':str(value),'MODE':mode}

    def test_each_brand_updates_only_selected_branch_and_repeat_is_noop(self):
        for branch in (self.branch,'main'):
            for brand in ('brand_a','brand_b'):
                with self.subTest(branch=branch,brand=brand):
                    ref='refs/heads/'+branch;source=self.tip(branch)
                    self.git('fetch','origin',ref,cwd=self.worker)
                    self.git('checkout','--detach',source,cwd=self.worker)
                    other_ref=self.branch if branch=='main' else 'main';untouched=self.tip(other_ref)
                    other_brand='brand_b' if brand=='brand_a' else 'brand_a';number=self.counter(ref,brand)
                    other_number=self.counter(ref,other_brand)
                    env={'BUILD_SOURCE_REF':ref,'BUILD_SOURCE_SHA':source,'FLAVOR':brand,'RESOLVED_BUILD_NUMBER':str(number+3)}
                    self.assert_ok(self.invoke(**env))
                    self.assertEqual(self.counter(ref,brand),number+4)
                    self.assertEqual(self.counter(ref,other_brand),other_number)
                    self.assertEqual(self.tip(other_ref),untouched)
                    count=self.tip(ref)
                    self.git('checkout','--detach',source,cwd=self.worker)
                    self.assert_ok(self.invoke(**env));self.assertEqual(self.tip(ref),count)

    def test_concurrent_same_brand_larger_number_wins_without_main_change(self):
        for brand in ('brand_a','brand_b'):
            with self.subTest(brand=brand):
                self.git('checkout','--detach',self.source,cwd=self.worker)
                self.git('fetch','origin',self.ref,cwd=self.other)
                self.git('reset','--hard','FETCH_HEAD',cwd=self.other)
                (self.root/'race').unlink(missing_ok=True)
                self.assert_ok(self.invoke(FLAVOR=brand,**self.race_environment(brand,60)))
                self.assertTrue((self.root/'race').exists())
                self.assertEqual(self.counter(self.ref,brand),60)
                self.assertEqual(self.git('show',self.ref+':independent-change.txt',cwd=self.origin),'must survive')
                self.assertEqual(self.tip('main'),self.main)

    def test_concurrent_other_brand_and_source_change_survive_retry(self):
        for brand,other_brand in [('brand_a','brand_b'),('brand_b','brand_a')]:
            with self.subTest(brand=brand):
                # Build 100/200 stays ahead of counters from the preceding case.
                built=100 if brand=='brand_a' else 200
                self.git('checkout','--detach',self.source,cwd=self.worker)
                self.git('fetch','origin',self.ref,cwd=self.other);self.git('reset','--hard','FETCH_HEAD',cwd=self.other)
                (self.root/'race').unlink(missing_ok=True)
                self.assert_ok(self.invoke(FLAVOR=brand,RESOLVED_BUILD_NUMBER=str(built),
                                           **self.race_environment(other_brand,built+10)))
                self.assertEqual(self.counter(self.ref,brand),built+1)
                self.assertEqual(self.counter(self.ref,other_brand),built+10)
                self.assertEqual(self.tip('main'),self.main)

    def test_same_brand_lower_concurrent_counter_is_advanced_after_retry(self):
        for brand in ('brand_a','brand_b'):
            with self.subTest(brand=brand):
                self.git('checkout','--detach',self.source,cwd=self.worker)
                self.git('fetch','origin',self.ref,cwd=self.other)
                self.git('reset','--hard','FETCH_HEAD',cwd=self.other)
                (self.root/'race').unlink(missing_ok=True)
                self.assert_ok(self.invoke(FLAVOR=brand,**self.race_environment(brand,42)))
                self.assertEqual(self.counter(self.ref,brand),51)
                self.assertEqual(self.git('show',self.ref+':independent-change.txt',cwd=self.origin),'must survive')
                self.assertEqual(self.tip('main'),self.main)

    def test_branch_with_same_named_tag_does_not_move_tag(self):
        self.git('update-ref','refs/tags/'+self.branch,self.main,cwd=self.origin)
        self.assert_ok(self.invoke())
        self.assertEqual(self.counter(self.ref,'brand_a'),51)
        self.assertEqual(self.tip('refs/tags/'+self.branch),self.main)
        self.assertEqual(self.tip('main'),self.main)

    def test_concurrent_main_publication_is_independent_of_upgrade(self):
        self.git('checkout','main',cwd=self.other)
        race=self.race_environment('brand_b',60)
        race['SOURCE_REF']='refs/heads/main'
        self.assert_ok(self.invoke(**race))
        self.assertEqual(self.counter(self.ref,'brand_a'),51)
        self.assertEqual(self.counter(self.ref,'brand_b'),7)
        self.assertEqual(self.counter('main','brand_a'),21)
        self.assertEqual(self.counter('main','brand_b'),60)
        self.assertEqual(self.tip('main'),self.git('rev-parse','HEAD',cwd=self.other).strip())

    def test_invalid_ref_tag_missing_branch_and_wrong_sha_never_write_main(self):
        for ref in ('','main','refs/tags/v0.9.1','refs/pull/1/head','refs/heads/a..b',
                    'refs/heads/test\nrefs/heads/main','refs/heads/missing'):
            with self.subTest(ref=ref):
                result=self.invoke(BUILD_SOURCE_REF=ref)
                self.assertNotEqual(result.returncode,0);self.assertEqual(self.tip('main'),self.main)
                self.assertEqual(self.tip(self.ref),self.source)
        self.assertNotEqual(self.invoke(BUILD_SOURCE_SHA='a'*40).returncode,0)
        self.assertEqual(self.tip('main'),self.main)

    def test_deleted_branch_is_not_recreated_after_fetch(self):
        result=self.invoke(**self.race_environment(mode='delete'))
        self.assertNotEqual(result.returncode,0)
        self.assertTrue((self.root/'race').exists())
        self.assertEqual(self.git('for-each-ref','--format=%(refname)',self.ref,cwd=self.origin),'')
        self.assertEqual(self.tip('main'),self.main)

    def test_rewritten_branch_and_missing_counter_are_rejected(self):
        self.git('update-ref',self.ref,self.main,cwd=self.origin)
        self.assertNotEqual(self.invoke().returncode,0)
        self.assertEqual(self.tip(self.ref),self.main)
        self.git('update-ref',self.ref,self.source,cwd=self.origin)
        self.git('rm','scripts/build_number.brand_a.txt',cwd=self.other)
        self.git('commit','-m','remove counter',cwd=self.other);self.git('push','origin',self.ref,cwd=self.other)
        self.assertNotEqual(self.invoke().returncode,0)
        self.assertEqual(self.tip('main'),self.main)

    def test_permanent_push_rejection_is_not_success_and_attempts_are_bounded(self):
        hook=self.origin/'hooks/pre-receive'
        hook.write_text('#!/bin/sh\necho attempt >> "'+str(self.root/'attempts')+'"\nexit 1\n');hook.chmod(0o755)
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('three attempts',result.stderr)
        self.assertEqual(len((self.root/'attempts').read_text().splitlines()),3)
        self.assertEqual(self.tip(self.ref),self.source);self.assertEqual(self.tip('main'),self.main)

    def test_dirty_worktree_and_symlink_counter_are_not_overwritten(self):
        file=self.worker/'upgrade-only.txt';file.write_text('uncommitted')
        self.assertNotEqual(self.invoke().returncode,0);self.assertEqual(file.read_text(),'uncommitted')
        self.git('reset','--hard',self.source,cwd=self.worker)
        path=self.other/'scripts/build_number.brand_a.txt';path.unlink();path.symlink_to('../upgrade-only.txt')
        self.git('add','.',cwd=self.other);self.git('commit','-m','unsafe counter',cwd=self.other)
        self.git('push','origin',self.ref,cwd=self.other)
        self.assertNotEqual(self.invoke().returncode,0)
        self.assertEqual(self.tip('main'),self.main)

    def test_old_fixed_main_writeback_violates_branch_isolation(self):
        old='''set -euo pipefail
git fetch --no-tags origin main
git reset --hard FETCH_HEAD
python3 tool/release_build_number.py advance --flavor "$FLAVOR"
git add scripts/build_number.brand_a.txt
git commit -m legacy-number
git push origin HEAD:main
'''
        result=subprocess.run(['bash','-c',old],cwd=self.worker,env=self.run_env,capture_output=True,text=True,timeout=20)
        self.assert_ok(result)
        self.assertNotEqual(self.tip('main'),self.main)
        self.assertEqual(self.counter('main','brand_a'),51)
        self.assertEqual(self.tip(self.ref),self.source)


class PublicationWorkflowTests(unittest.TestCase):
    def test_formal_entry_preserves_source_branch_and_tag_skip(self):
        workflow=(Path(__file__).resolve().parents[2]/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        self.assertIn('source_ref: ${{ steps.request.outputs.source_ref }}',workflow)
        bump=workflow.split('\n  bump:\n',1)[1]
        self.assertIn("if: needs.setup.outputs.upload == 'true' && startsWith(needs.setup.outputs.source_ref, 'refs/heads/')",bump)
        self.assertIn('needs: [setup, package]',bump)
        self.assertIn('fetch-depth: 0',bump)
        self.assertIn('BUILD_SOURCE_REF: ${{ needs.setup.outputs.source_ref }}',bump)
        self.assertIn('BUILD_SOURCE_SHA: ${{ needs.setup.outputs.source_sha }}',bump)
        script=step_script('Increment build_number for flavor')
        self.assertIn('cp tool/release_build_number.py "$NUMBER_TOOL"',script)
        self.assertIn('python3 "$NUMBER_TOOL" publish --flavor "$FLAVOR"',script)
        self.assertNotIn('HEAD:main',script)
        self.assertNotIn('origin main',script)


if __name__ == '__main__':
    unittest.main()
