"""File encoding guard used by the shared gate and every native matrix runner."""
import ast
from contextlib import contextmanager
import os
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest import mock
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import android_release_contract_test as android_tests
import local_release_automation_test as release_tests


@contextmanager
def legacy_file_encoding():
    original = Path.open
    original_read = Path.read_text
    original_write = Path.write_text
    def legacy_open(path, mode='r', buffering=-1, encoding=None, errors=None, newline=None):
        if 'b' not in mode and encoding in (None, 'locale'):
            encoding = 'cp1252'
        return original(path, mode=mode, buffering=buffering, encoding=encoding, errors=errors, newline=newline)
    # read_text/write_text can resolve None to UTF-8 before calling open when
    # Python UTF-8 mode is enabled. Intercept their public defaults as well.
    def legacy_read(path, encoding=None, errors=None):
        return original_read(path, encoding=encoding or 'cp1252', errors=errors)
    def legacy_write(path, data, encoding=None, errors=None, newline=None):
        return original_write(path, data, encoding=encoding or 'cp1252', errors=errors, newline=newline)
    with mock.patch.object(Path, 'open', legacy_open), mock.patch.object(Path, 'read_text', legacy_read), mock.patch.object(Path, 'write_text', legacy_write):
        yield


def implicit_path_text_calls(source):
    tree = ast.parse(source)
    missing = [n.lineno for n in ast.walk(tree)
               if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
               and n.func.attr in ('read_text', 'write_text')
               and not any(k.arg == 'encoding' for k in n.keywords)]
    # Executable fixture scripts also need the protocol. Parse complete Python
    # string literals, leaving non-code/partial strings to runtime tests.
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and any(
                text in node.value for text in ('.read_text(', '.write_text(')):
            try:
                nested = implicit_path_text_calls(node.value)
            except SyntaxError:
                continue
            missing.extend((node.lineno, line) for line in nested)
    return missing


class TextEncodingTests(unittest.TestCase):
    def test_maintained_text_io_is_explicit(self):
        for name in ['tool/test/android_release_contract_test.py', 'tool/test/local_release_automation_test.py',
                     'tool/test/android_version_gradle_test.py', 'tool/apk_archive.py',
                     'tool/check_android_release_contract.py', 'tool/check_fallback_assets.py',
                     'tool/build_android_local.py']:
            with self.subTest(path=name):
                self.assertEqual(implicit_path_text_calls((ROOT / name).read_text(encoding='utf-8')), [])
        self.assertTrue(implicit_path_text_calls('p.read_text()'))
        self.assertTrue(implicit_path_text_calls('p.write_text("x")'))
        self.assertEqual(implicit_path_text_calls('p.read_bytes()'), [])
        self.assertTrue(implicit_path_text_calls('script = ' + repr('p.write_text("x")')))
        self.assertEqual(implicit_path_text_calls('script = ' + repr('p.write_text("x", encoding="utf-8")')), [])

    def test_real_repository_consumers_with_non_ascii_under_cp1252(self):
        # Fixed Chinese text guarantees the old read fails even if the real
        # repository happens to contain only ASCII in a future version.
        with tempfile.TemporaryDirectory(prefix='encoding-') as temporary:
            root = Path(temporary)
            workflow = root / '.github/workflows/release-package.yml'
            gradle = root / 'plugins/crisp_chat/android/build.gradle'
            for path in [workflow, gradle]: path.parent.mkdir(parents=True, exist_ok=True)
            workflow.write_text('# 持续集成\n            build/android-release-contract/\n', encoding='utf-8')
            version = android_tests.contract.CRISP_CONTRACT['sdk_version']
            gradle.write_text('// 持续集成\nimplementation "im.crisp:crisp-sdk:' + version + '"\n', encoding='utf-8')
            with mock.patch.object(android_tests.contract, 'ROOT', root), legacy_file_encoding():
                case = android_tests.ContractTest()
                case.test_ci_entry_diagnoses_both_apks_before_failing()
                case.test_sdk_pin_matches_resource_inventory()
                for path in [workflow, gradle]:
                    with self.assertRaises(UnicodeDecodeError): path.read_text()
                with self.assertRaises(UnicodeEncodeError):
                    (root / 'old-writer.txt').write_text('持续集成')

    def test_simulation_works_in_both_utf8_modes(self):
        for mode in ['0', '1']:
            with self.subTest(utf8_mode=mode):
                result = subprocess.run([sys.executable, '-X', 'utf8=' + mode, str(Path(__file__).resolve()),
                    'TextEncodingTests.test_real_repository_consumers_with_non_ascii_under_cp1252'],
                    cwd=ROOT, capture_output=True, timeout=60)
                self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode('utf-8', errors='replace'))

    def test_complete_affected_suites_under_cp1252(self):
        suite = unittest.TestSuite([
            unittest.defaultTestLoader.loadTestsFromTestCase(android_tests.ContractTest),
        ])
        # Run the actual existing cases; on Windows their genuine POSIX-only
        # skips remain skips, rather than claiming shell execution there.
        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(release_tests))
        import io
        stream = io.StringIO()
        with legacy_file_encoding():
            result = unittest.TextTestRunner(stream=stream, verbosity=1).run(suite)
        self.assertTrue(result.wasSuccessful(), stream.getvalue())
        self.assertGreater(result.testsRun, 70)
        if os.name == 'posix': self.assertEqual(result.skipped, [], stream.getvalue())


if __name__ == '__main__':
    unittest.main()
