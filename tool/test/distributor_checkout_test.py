"""Cold immutable checkout with real Git and a local public-source mirror."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tool'))
import checkout_distributor as checkout


class CleanDistributorCheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='distributor-cold-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.source=self.root/'remote';self.source.mkdir()
        self.git(self.source,'init','--quiet','--template=')
        (self.source/'marker').write_text('pinned')
        self.git(self.source,'add','marker');self.commit()
        self.pin=self.git(self.source,'rev-parse','HEAD').strip()
        (self.source/'marker').write_text('new-tip');self.git(self.source,'add','marker');self.commit()
        self.project=self.root/'client';self.project.mkdir()
    def git(self,root,*args):
        return subprocess.check_output(['git','-C',str(root),*args],stderr=subprocess.PIPE,text=True)
    def commit(self):
        self.git(self.source,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgSign=false','commit','--quiet','-m','fixture')
    def run_checkout(self,revision=None,url=None):
        return checkout.ensure_checkout(self.project,url=url or self.source.as_uri(),revision=revision or self.pin)
    def test_exact_pin_not_remote_tip_and_repeat_does_not_mutate(self):
        result=self.run_checkout()
        self.assertEqual((result/'marker').read_text(),'pinned')
        self.assertEqual(self.git(result,'rev-parse','HEAD').strip(),self.pin)
        self.assertEqual(self.run_checkout(),result)
        self.assertFalse((self.project/'plugins').exists())
    def test_unknown_pin_and_missing_source_fail_without_promoting_checkout(self):
        for options in ({'revision':'f'*40},{'url':(self.root/'missing').as_uri()}):
            with self.subTest(options=options),self.assertRaises(RuntimeError):self.run_checkout(**options)
            self.assertFalse((self.project/checkout.RELATIVE).exists())
    def test_modified_source_and_wrong_existing_revision_are_rejected(self):
        result=self.run_checkout();(result/'marker').write_text('modified')
        with self.assertRaises(RuntimeError):self.run_checkout()
        self.git(result,'restore','marker')
        with self.assertRaises(RuntimeError):self.run_checkout(revision='f'*40)
    def test_default_source_is_explicit_https_and_pin_is_immutable(self):
        self.assertEqual(checkout.URL,'https://github.com/chen08209/flutter_distributor.git')
        self.assertRegex(checkout.PINNED_REVISION,r'^[a-f0-9]{40}$')
        workflow=(ROOT/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        self.assertIn('run: python3 tool/checkout_distributor.py',workflow)
        self.assertNotIn('submodule.plugins/flutter_distributor.url=',workflow)


if __name__=='__main__':unittest.main()
