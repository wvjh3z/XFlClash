"""Real Flutter hook filtering/cache hashing + native child process controls.

Only compiles a tiny fake rustup executable; never compiles a client/core or
uploads symbols. Target files are fixtures, not real PDB/DWARF verification.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import tomllib
from urllib.parse import urlparse
from urllib.request import url2pathname

ROOT = Path(__file__).resolve().parents[2]
PINS = json.loads((ROOT/'tool/native_toolchain.json').read_text(encoding='utf-8'))


def invoke(argv, **kwargs):
    return subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                          encoding='utf-8', errors='replace', timeout=120, **kwargs)


class HookBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='native-hook-中文-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name)
        flutter = Path(os.environ['FLUTTER_ROOT'])
        cls.dart = flutter/('bin/cache/dart-sdk/bin/dart.exe' if os.name == 'nt' else 'bin/cache/dart-sdk/bin/dart')
        cls.tools_graph = flutter/'packages/flutter_tools/.dart_tool/package_config.json'
        cls.app_graph = ROOT/'.dart_tool/package_config.json'
        if not all(path.is_file() for path in (cls.dart, cls.tools_graph, cls.app_graph)):
            raise RuntimeError('Prepare the formal Flutter/client pub graph before hook checks')
        cls.probe_source = cls.base/'hook_probe.dart'
        shutil.copyfile(ROOT/'tool/test/fixtures/native_hook_probe.dart.fixture', cls.probe_source)
        cls.fake_bin = cls.base/'bin';cls.fake_bin.mkdir()
        cls.fake = cls.fake_bin/('rustup.exe' if os.name == 'nt' else 'rustup')
        # Standalone source, outside the application pub graph: no native hooks.
        source = cls.base/'fake.dart';shutil.copyfile(ROOT/'tool/test/fake_rustup.dart', source)
        result = invoke([cls.dart, 'compile', 'exe', source, '-o', cls.fake], cwd=cls.base)
        if result.returncode: raise RuntimeError(result.stdout + result.stderr)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='case-', dir=self.base)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root/'tool').mkdir()
        shutil.copyfile(ROOT/'tool/native_toolchain.json', self.root/'tool/native_toolchain.json')
        crate = self.root/'services/helper';crate.mkdir(parents=True)
        (crate/'Cargo.toml').write_text('[package]\nname="helper"\nversion="0.0.1"\n', encoding='utf-8')
        self.control = self.fake_bin/'control.json'
        self.configure()
        environment = {key: value for key, value in os.environ.items() if key.upper() in {
            'PATH','HOME','APPDATA','LOCALAPPDATA','USERPROFILE','SYSTEMROOT','SYSTEMDRIVE','WINDIR','TEMP','TMP','TMPDIR','PATHEXT'}}
        environment.update(RUSTUP_TOOLCHAIN='invalid-parent-selection', CARGO_HOME='invalid-parent-home', RUSTUP_HOME='invalid-parent-home')
        environment['PATH'] = str(self.fake_bin)+os.pathsep+environment.get('PATH','')
        self.env_input=self.root/'env.json';self.env_output=self.root/'filtered.json'
        self.env_input.write_text(json.dumps(environment),encoding='utf-8')
        self.probe('filter', self.env_input, self.env_output)
        self.environment=json.loads(self.env_output.read_text(encoding='utf-8'))

    def configure(self, **values):
        self.control.write_text(json.dumps(dict(pin=PINS['rust'], **values)),encoding='utf-8')

    def probe(self, *args):
        result=invoke([self.dart, '--packages='+str(self.tools_graph), self.probe_source, *args])
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def fixture(self, mode, platform, arch='amd64', succeeds=True):
        result=invoke([self.dart, '--packages='+str(self.app_graph), ROOT/'tool/test/native_symbol_cache_fixture.dart', mode, self.root, platform, arch],env=self.environment)
        if succeeds:
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode,0)
        return result

    def test_real_filter_and_fixed_child_command_reject_wrong_versions(self):
        for name in ('RUSTUP_TOOLCHAIN','CARGO_HOME','RUSTUP_HOME'):self.assertNotIn(name,self.environment)
        old=invoke([self.fake,'--version'],env=self.environment)
        self.assertEqual(old.returncode,91,'negative control must reject the old unpinned invocation')
        self.assertTrue(self.fixture('helper','windows')['rebuilt'])
        self.configure(wrongVersion=True)
        result=self.fixture('helper','windows',succeeds=False)
        self.assertIn('differs from the fixed version',result.stderr)

    def test_real_rustup_runs_fixed_toolchain_after_actual_filtering(self):
        cargo_home = Path(os.environ.get('CARGO_HOME', str(Path.home()/'.cargo')))
        rustup = cargo_home/('bin/rustup.exe' if os.name == 'nt' else 'bin/rustup')
        self.assertTrue(rustup.is_file(), 'Formal native preparation must install rustup')
        environment = dict(self.environment)
        # Do not use this developer machine's wrapper or the fake executable.
        environment['PATH'] = os.pathsep.join(part for part in environment.get('PATH','').split(os.pathsep)
                                             if part != str(self.fake_bin) and 'native-launchers' not in part)
        rustup_home = Path(os.environ.get('RUSTUP_HOME', str(Path.home()/'.rustup')))
        if rustup_home.resolve() != (Path.home()/'.rustup').resolve():
            # Test the default-home lookup used by a clean Runner without
            # copying gigabytes or modifying the user's rustup configuration.
            home = self.root/'isolated-home';home.mkdir()
            (home/'.rustup').symlink_to(rustup_home, target_is_directory=True)
            environment['HOME'] = str(home)
            if os.name == 'nt': environment['USERPROFILE'] = str(home)
        good=invoke([rustup,'run',PINS['rust'],'rustc','--version'],cwd=self.root,env=environment)
        self.assertEqual(good.returncode,0,good.stderr)
        self.assertTrue(good.stdout.startswith('rustc '+PINS['rust']+' '),good.stdout)
        bad=invoke([rustup,'run','xflclash-uninstalled-control','rustc','--version'],cwd=self.root,env=environment)
        self.assertNotEqual(bad.returncode,0,'Missing fixed toolchain must not fall back to default')

    def test_actual_rust_manifest_validator_accepts_targets_and_rejects_omission(self):
        folder=self.root/'manifest';folder.mkdir()
        shutil.copyfile(ROOT/'plugins/rust_api/rust/Cargo.toml',folder/'Cargo.toml')
        path=folder/'rust-toolchain.toml'
        source=(ROOT/'plugins/rust_api/rust/rust-toolchain.toml').read_text(encoding='utf-8')
        path.write_text(source,encoding='utf-8')
        targets=tomllib.loads(source)['toolchain']['targets']
        self.assertGreaterEqual(len(targets),8)
        for target in targets:
            self.assertEqual(self.fixture('manifest',target)['toolchain'],PINS['rust'])
        path.write_text('[toolchain]\nchannel="'+PINS['rust']+'"\nprofile="minimal"\n',encoding='utf-8')
        missing=self.fixture('manifest',targets[0],succeeds=False)
        self.assertIn('toolchain.targets',missing.stderr)
        path.write_text(source,encoding='utf-8')
        self.fixture('manifest','unsupported-target-control',succeeds=False)

    def test_helper_cache_recovers_private_outputs_and_contents(self):
        for platform in ('windows','linux'):
            with self.subTest(platform=platform):
                first=self.fixture('helper',platform)
                self.assertTrue(first['rebuilt'])
                self.assertFalse(self.fixture('helper',platform)['rebuilt'])
                files=[Path(p) for p in first['outputs']]
                private=next(p for p in files if p.suffix=='.pdb') if platform=='windows' else next(p for p in files if 'target' in p.parts)
                private.unlink()
                self.assertTrue(self.fixture('helper',platform)['rebuilt'])
                self.assertTrue(private.exists())
                stat=private.stat();payload=private.read_bytes()
                private.write_bytes(b'X'*len(payload));os.utime(private,ns=(stat.st_atime_ns,stat.st_mtime_ns))
                self.assertTrue(self.fixture('helper',platform)['rebuilt'])
                self.assertEqual(private.read_bytes(),payload)
                shutil.rmtree(self.root/'services/helper/target')
                self.assertTrue(self.fixture('helper',platform)['rebuilt'])
                self.assertTrue(self.fixture('helper',platform,'arm64')['rebuilt'])
                # Shared platform runtime is replaced on an architecture switch;
                # the previous architecture must rebuild before reuse.
                self.assertTrue(self.fixture('helper',platform)['rebuilt'])
                self.assertFalse(self.fixture('helper',platform)['rebuilt'])

    def test_helper_failure_cannot_publish_missing_pdb_or_replace_old_runtime(self):
        first=self.fixture('helper','windows')
        runtime=Path(first['outputs'][0]);before=runtime.read_bytes()
        pdb=next(Path(p) for p in first['outputs'] if p.endswith('.pdb'));pdb.unlink()
        self.configure(failBuild=True)
        self.fixture('helper','windows',succeeds=False)
        self.assertEqual(runtime.read_bytes(),before)
        self.configure(omitPdb=True)
        self.fixture('helper','windows',succeeds=False)
        self.configure()
        self.assertTrue(self.fixture('helper','windows')['rebuilt'])

    def test_real_hook_hash_detects_nested_symbols_and_recovery(self):
        for platform in ('android','linux','windows','macos'):
            with self.subTest(platform=platform):
                captured=self.fixture('capture',platform)
                deps=self.root/'deps.json';deps.write_text(json.dumps(captured),encoding='utf-8')
                hashes=self.root/'hashes.json'
                self.probe('record',deps,hashes)
                self.assertFalse(self.probe('check',deps,hashes)['invalidated'])
                paths=[Path(url2pathname(urlparse(uri).path)) for uri in captured['dependencies']]
                files=[p for p in paths if p.is_file() and p.name!='manifest.json']
                symbol=next(p for p in files if 'DWARF' in p.parts) if platform=='macos' else files[0]
                payload=symbol.read_bytes();symbol.unlink()
                self.assertTrue(self.probe('check',deps,hashes)['invalidated'])
                recovered=self.fixture('capture',platform)
                self.assertEqual(symbol.read_bytes(),payload)
                self.assertEqual(recovered,captured)
                self.probe('record',deps,hashes)
                stat=symbol.stat();symbol.write_bytes(b'X'*len(payload));os.utime(symbol,ns=(stat.st_atime_ns,stat.st_mtime_ns))
                self.assertTrue(self.probe('check',deps,hashes)['invalidated'])
                self.fixture('capture',platform)
                self.assertEqual(symbol.read_bytes(),payload)
                if platform!='windows':
                    self.fixture('capture',platform,'arm64')
                    self.assertEqual(symbol.read_bytes(),payload)


if __name__=='__main__':unittest.main(verbosity=2)
