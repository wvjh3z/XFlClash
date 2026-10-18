"""No builds: real POSIX groups plus controlled Darwin/error boundary cases."""
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import owned_process_cleanup as cleanup
from ready_process_tree import ReadyTree, STARTUP_TIMEOUT


class InventoryTests(unittest.TestCase):
    def query(self, output):
        with mock.patch.object(cleanup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')) as run:
            value = cleanup.group_state(555, .1)
        self.assertEqual(run.call_args.args[0], ['/bin/ps', '-A', '-o', 'pgid=', '-o', 'stat='])
        self.assertEqual(run.call_args.kwargs['env']['LC_ALL'], 'C')
        return value

    def test_bsd_and_gnu_states(self):
        self.assertEqual(self.query('    555 Ss+\n 123 R\n'), 'live')
        self.assertEqual(self.query('555 ZN\n555 Z+\n123 S\n'), 'zombies_only')
        self.assertEqual(self.query('123 S\n'), 'gone')
        self.assertEqual(self.query('555 Z\n555 I<\n'), 'live')

    def test_invalid_or_missing_inventory_is_never_success(self):
        for value in ('', 'PID STAT\n', '555\n', '555 Z command\n', '555 ###\n'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.query(value)

    def test_diagnostic_is_bounded_and_drops_messages_and_paths(self):
        detail = cleanup.safe_cleanup({'outcome': 'failed', 'phase': 'verify', 'pid': 123,
            'argv': '/private/token', 'errors': [{'phase': 'kill', 'kind': 'permission', 'errno': 1,
                                               'message': 'private-token'}] * 20})
        self.assertEqual(len(detail['errors']), 8)
        self.assertNotIn('private', json.dumps(detail))
        self.assertNotIn('pid', detail)
        self.assertEqual(cleanup.safe_cleanup({'errors': None})['errors'], [])


@unittest.skipUnless(os.name == 'posix', 'POSIX private groups; Windows tests use real Job objects')
class BoundaryTests(unittest.TestCase):
    def process(self):
        return mock.Mock(pid=87654321, returncode=0)

    def test_eperm_before_reap_and_absent_group_after_reap_is_success(self):
        process = self.process()
        with mock.patch.object(cleanup.os, 'killpg', side_effect=[PermissionError(errno.EPERM, 'private'), ProcessLookupError()]), \
             mock.patch.object(cleanup, 'group_state', return_value='gone'):
            result = cleanup.cleanup_owned_group(process)
        self.assertTrue(result['permission_race_recovered'])
        self.assertTrue(result['reaped'])
        self.assertEqual(result['errors'], [{'phase': 'term', 'kind': 'permission', 'errno': 1}])
        self.assertEqual(process.wait.call_count, 2)

    def test_eperm_with_live_descendant_still_fails(self):
        process = self.process()
        with mock.patch.object(cleanup.os, 'killpg', side_effect=PermissionError(errno.EPERM, 'private')), \
             mock.patch.object(cleanup, 'group_state', return_value='live'), self.assertRaises(cleanup.CleanupError) as raised:
            cleanup.cleanup_owned_group(process, timeout=.06)
        self.assertEqual(raised.exception.diagnostic['group_state'], 'live')
        self.assertTrue(raised.exception.diagnostic['reaped'])
        self.assertEqual(process.wait.call_count, 2)

    def test_no_permission_error_is_swallowed_when_inventory_unknown(self):
        for error in (FileNotFoundError('private'), subprocess.TimeoutExpired('private', 1), ValueError('private')):
            with self.subTest(error=type(error).__name__), \
                 mock.patch.object(cleanup.os, 'killpg', side_effect=PermissionError(errno.EPERM, 'private')), \
                 mock.patch.object(cleanup, 'group_state', side_effect=error), self.assertRaises(cleanup.CleanupError) as raised:
                cleanup.cleanup_owned_group(self.process())
            self.assertEqual(raised.exception.diagnostic['group_state'], 'unknown')

    def test_unknown_signal_error_fails_but_still_reaps(self):
        process = self.process()
        with mock.patch.object(cleanup.os, 'killpg', side_effect=OSError(errno.EIO, 'private')), \
             mock.patch.object(cleanup, 'group_state', return_value='gone'), self.assertRaises(cleanup.CleanupError):
            cleanup.cleanup_owned_group(process)
        self.assertEqual(process.wait.call_count, 2)

    def test_wait_failure_still_attempts_kill_and_final_wait(self):
        process = self.process()
        process.wait.side_effect = [ChildProcessError('private'), 0]
        with mock.patch.object(cleanup.os, 'killpg') as kill, \
             mock.patch.object(cleanup, 'group_state', return_value='gone'), self.assertRaises(cleanup.CleanupError):
            cleanup.cleanup_owned_group(process)
        self.assertEqual([c.args[1] for c in kill.call_args_list], [signal.SIGTERM, signal.SIGKILL])
        self.assertEqual(process.wait.call_count, 2)

    def test_delayed_kill_completion_is_polled_with_bound(self):
        with mock.patch.object(cleanup.os, 'killpg'), \
             mock.patch.object(cleanup, 'group_state', side_effect=['live', 'live', 'zombies_only']) as query:
            result = cleanup.cleanup_owned_group(self.process(), timeout=.5)
        self.assertEqual(query.call_count, 3)
        self.assertEqual(result['group_state'], 'zombies_only')

    def test_never_signal_current_or_zero_group(self):
        for pid in (0, 1, -1, os.getpgrp()):
            with mock.patch.object(cleanup.os, 'killpg') as kill, self.assertRaises(cleanup.CleanupError):
                cleanup.cleanup_owned_group(mock.Mock(pid=pid))
            kill.assert_not_called()

    def test_real_short_lived_process_and_running_process(self):
        process = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
        try:
            self.assertEqual(process.wait(timeout=STARTUP_TIMEOUT), 0)
            self.assertEqual(cleanup.cleanup_owned_group(process)['outcome'], 'complete')
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        with tempfile.TemporaryDirectory() as directory, ReadyTree(directory) as tree:
            process = subprocess.Popen(tree.command, start_new_session=True)
            try:
                tree.assert_alive()
                result = cleanup.cleanup_owned_group(process)
                self.assertEqual(result['outcome'], 'complete')
                self.assertIsNotNone(process.returncode)
                tree.assert_closed()
            finally:
                tree.close()
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)

    def test_real_leader_exited_but_descendant_holds_pipe(self):
        with tempfile.TemporaryDirectory() as directory, ReadyTree(directory) as tree:
            process = subprocess.Popen(tree.command, stdout=subprocess.PIPE, start_new_session=True)
            try:
                tree.assert_alive()
                tree.exit_parent()
                process.wait(timeout=5)
                result = cleanup.cleanup_owned_group(process)
                self.assertEqual(result['outcome'], 'complete')
                self.assertIn(result['group_state'], ('gone', 'zombies_only'))
                tree.assert_closed()
                self.assertEqual(process.stdout.read(), b'')
            finally:
                tree.close()
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
                process.stdout.close()


if __name__ == '__main__':
    unittest.main()
