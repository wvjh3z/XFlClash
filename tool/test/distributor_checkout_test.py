"""Cold submodule checkout contract for the Ubuntu setup job.

Execute the real workflow Bash command with real Git. Only HTTPS's remote is
mapped to an isolated local bare mirror; SSH is explicitly rejected. No network,
user credentials, initialized production submodule, Flutter or client build.
"""
from pathlib import Path
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tool.test.sentry_release_workflow_test import step_script

HTTPS = 'https://github.com/chen08209/flutter_distributor.git'
KEY = 'submodule.plugins/flutter_distributor.url'
MODULE = 'plugins/flutter_distributor'


@unittest.skipUnless(os.name == 'posix' and shutil.which('git') and shutil.which('bash'),
                     'Cold checkout fixture executes the POSIX setup-job shell')
class CleanDistributorCheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='distributor-cold-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.config = self.root / 'test-global.config'
        self.config.write_bytes(b'')
        self.ssh_marker = self.root / 'ssh-used'
        reject_ssh = self.root / 'reject-ssh.sh'
        reject_ssh.write_bytes(b'#!/bin/sh\nprintf used >> "$XFL_TEST_SSH_MARKER"\nexit 91\n')
        reject_ssh.chmod(0o700)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith('GIT_') and k not in ('SSH_AUTH_SOCK', 'SSH_AGENT_PID')}
        self.env.update(GIT_CONFIG_GLOBAL=str(self.config), GIT_CONFIG_NOSYSTEM='1',
                        GIT_TERMINAL_PROMPT='0', GIT_ALLOW_PROTOCOL='file:ssh',
                        GIT_SSH_COMMAND=shlex.quote(str(reject_ssh)),
                        XFL_TEST_SSH_MARKER=str(self.ssh_marker), LC_ALL='C')
        source = self.root / 'upstream'
        self.git('init', '--quiet', '--template=', '--initial-branch=main', source)
        (source / 'marker').write_bytes(b'pinned\n')
        self.git('add', 'marker', cwd=source)
        self.commit(source, 'pinned')
        self.pin = self.git('rev-parse', 'HEAD', cwd=source).stdout.strip().decode('ascii')
        (source / 'marker').write_bytes(b'newer remote HEAD\n')
        self.git('add', 'marker', cwd=source)
        self.commit(source, 'newer')
        self.tip = self.git('rev-parse', 'HEAD', cwd=source).stdout.strip().decode('ascii')
        self.assertNotEqual(self.pin, self.tip)
        self.remote = self.root / 'mirror.git'
        self.git('clone', '--bare', '--quiet', source, self.remote)
        # Test-only HTTPS -> local mirror mapping. There is deliberately no
        # git@github.com -> HTTPS rule to mask #106. The real anonymous HTTPS
        # fetch is checked separately as a local pre-submit smoke test.
        self.git('config', '--file', self.config, 'url.' + self.remote.as_uri() + '.insteadOf', HTTPS)
        self.config_before = self.config.read_bytes()
        self.repo = self.root / 'checkout'
        self.git('init', '--quiet', '--template=', self.repo)
        self.modules_bytes = (ROOT / '.gitmodules').read_bytes()
        (self.repo / '.gitmodules').write_bytes(self.modules_bytes)
        self.git('add', '.gitmodules', cwd=self.repo)
        for name in ('core/Clash.Meta', MODULE, 'plugins/tray_manager'):
            self.git('update-index', '--add', '--cacheinfo', '160000', self.pin, name, cwd=self.repo)
        self.script = step_script('Prepare pinned distributor for shared checks')
        self.assert_cold()

    def git(self, *args, cwd=None, check=True):
        return subprocess.run(['git', *map(str, args)], cwd=cwd or self.root, env=self.env,
                              capture_output=True, check=check, timeout=30)

    def commit(self, repo, message):
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgSign=false', 'commit', '--quiet', '-m', message, cwd=repo)

    def assert_cold(self):
        self.assertFalse((self.repo / MODULE).exists())
        self.assertFalse((self.repo / '.git/modules').exists())
        result = self.git('config', '--local', '--get', KEY, cwd=self.repo, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.ssh_marker.exists())

    def execute(self, script=None):
        return subprocess.run(['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c',
                               self.script if script is None else script], cwd=self.repo,
                              env=self.env, capture_output=True, timeout=60)

    def assert_pinned(self):
        child = self.repo / MODULE
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=child).stdout.strip().decode('ascii'), self.pin)
        self.assertEqual((child / 'marker').read_bytes(), b'pinned\n')
        self.assertEqual((self.repo / '.gitmodules').read_bytes(), self.modules_bytes)
        for name in ('core/Clash.Meta', 'plugins/tray_manager'):
            self.assertFalse((self.repo / name).exists())
            self.assertFalse((self.repo / '.git/modules' / name).exists())
        self.assertEqual(self.config.read_bytes(), self.config_before)
        self.assertFalse(self.ssh_marker.exists())

    def test_real_workflow_initializes_only_selected_gitlink_over_https(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
        self.assert_pinned()
        # Retry is also safe, but cannot be substituted for the cold assertion.
        self.assertEqual(self.execute().returncode, 0)
        self.assert_pinned()

    def test_old_command_uses_ssh_and_fails_without_keys(self):
        result = self.execute('git submodule update --init --depth 1 -- plugins/flutter_distributor')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.ssh_marker.exists())
        self.assertFalse((self.repo / MODULE / 'marker').exists())
        self.assertEqual(self.config.read_bytes(), self.config_before)

    def test_unreachable_https_mirror_fails_without_ssh_fallback(self):
        self.config.write_bytes(b'')
        missing = self.root / 'missing.git'
        self.git('config', '--file', self.config, 'url.' + missing.as_uri() + '.insteadOf', HTTPS)
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.ssh_marker.exists())
        self.assertFalse((self.repo / MODULE / 'marker').exists())

    def test_wrong_gitlink_fails_instead_of_using_remote_tip(self):
        wrong = 'f' * 40
        self.git('update-index', '--cacheinfo', '160000', wrong, MODULE, cwd=self.repo)
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.ssh_marker.exists())
        head = self.git('rev-parse', 'HEAD', cwd=self.repo / MODULE, check=False)
        self.assertNotEqual(head.stdout.strip(), wrong.encode())


if __name__ == '__main__':
    if os.name != 'posix' or not shutil.which('git') or not shutil.which('bash'):
        raise SystemExit('This cold-checkout gate requires the POSIX/Bash/Git setup-job environment')
    unittest.main()
