"""Real PowerShell/CMake path protocol fixtures; no app compilation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = os.environ.get('XFL_TEST_POWERSHELL') or shutil.which('powershell') or shutil.which('pwsh')
RESOLVER = ROOT / 'plugins/rust_api/cargokit/cmake/resolve_symlinks.ps1'


def cmake_literal(value):
    """Keep spaces, brackets and shell metacharacters literal in CMake input."""
    marker = '='
    while ']' + marker + ']' in str(value):
        marker += '='
    return '[' + marker + '[' + str(value) + ']' + marker + ']'


@unittest.skipUnless(POWERSHELL and shutil.which('cmake'), 'PowerShell and CMake required')
class PathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cargokit-path-')
        self.addCleanup(self.temp.cleanup)
        # Preserve the host spelling as input, but compare canonical targets.
        # Windows TEMP may contain RUNNER~1 instead of runneradmin.
        self.root = Path(self.temp.name)
        self.directory = self.root / '中文 ! [路径] & ()'
        self.directory.mkdir()

    def resolve(self, path):
        return subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', str(RESOLVER), str(path)],
            capture_output=True, timeout=30)

    def assert_resolved(self, result, target):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b'')
        # Exact UTF-8/no BOM/newline/extra output, plus actual target identity.
        expected = target.resolve(strict=True).as_posix()
        self.assertEqual(result.stdout, expected.encode('utf-8'))
        self.assertTrue(os.path.samefile(result.stdout.decode('utf-8'), target))

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')
        self.assertIn(b'Cargokit path resolution failed:', result.stderr)

    def link(self, name, target):
        link = self.root / name
        if os.name == 'nt':
            subprocess.run(['cmd', '/d', '/c', 'mklink', '/J', str(link), str(target)],
                           check=True, capture_output=True, timeout=30)
            self.addCleanup(lambda: os.rmdir(link) if os.path.lexists(link) else None)
        else:
            link.symlink_to(target.name, target_is_directory=True)
        return link

    def windows_short_path(self, path):
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.GetShortPathNameW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD]
        kernel.GetShortPathNameW.restype = wintypes.DWORD
        source = str(path.resolve(strict=True))
        required = kernel.GetShortPathNameW(source, None, 0)
        if not required:
            raise ctypes.WinError(ctypes.get_last_error())
        buffer = ctypes.create_unicode_buffer(required)
        count = kernel.GetShortPathNameW(source, buffer, required)
        if not count or count >= required:
            raise RuntimeError('Cannot obtain actual Windows short-path control')
        # Do not silently pass a purported short-path test on a volume without
        # 8.3 aliases. Windows release CI and native validation must exercise it.
        self.assertNotEqual(buffer.value.casefold(), source.casefold(),
                            'Native short-path regression requires an 8.3-enabled temporary volume')
        self.assertTrue(os.path.samefile(buffer.value, source))
        return Path(buffer.value)

    def test_literal_chinese_path_is_exact_utf8_without_bom(self):
        self.assert_resolved(self.resolve(self.directory), self.directory)

    def test_long_and_native_short_paths_resolve_to_same_directory(self):
        long_path = self.directory.resolve(strict=True)
        inputs = [self.directory, long_path]
        if os.name == 'nt':
            # Only the parent is abbreviated; the Chinese literal suffix stays
            # present, reproducing RUNNER~1 plus [brackets] from Actions.
            inputs.append(self.windows_short_path(self.root) / self.directory.name)
        for path in inputs:
            with self.subTest(path=path):
                self.assert_resolved(self.resolve(path), long_path)

    def missing_paths(self):
        return [self.directory / 'missing', self.directory / 'missing' / 'child',
                self.root / 'plain-missing', self.root / 'plain-missing' / 'child']

    def test_missing_leaf_and_parent_are_failure_without_machine_output(self):
        for path in self.missing_paths():
            with self.subTest(path=path):
                self.assert_rejected(self.resolve(path))

    def test_file_is_not_a_directory_or_parent(self):
        file = self.directory / 'file.txt'
        file.write_bytes(b'file must survive')
        for path in (file, file / 'child'):
            with self.subTest(path=path):
                self.assert_rejected(self.resolve(path))
        self.assertEqual(file.read_bytes(), b'file must survive')

    def test_parent_junction_or_relative_link_and_nested_target(self):
        link = self.link('alias', self.directory)
        child = self.directory / 'child'; child.mkdir()
        nested = self.link('nested-alias', link)
        for path, target in ((link, self.directory), (link / 'child', child),
                             (nested / 'child', child)):
            with self.subTest(path=path):
                self.assert_resolved(self.resolve(path), target)
        self.assert_rejected(self.resolve(link / 'missing'))
        self.assert_rejected(self.resolve(nested / 'missing' / 'child'))

    def test_broken_junction_or_link_is_failure(self):
        target = self.root / 'target'; target.mkdir()
        link = self.link('broken', target)
        target.rmdir()
        self.assert_rejected(self.resolve(link))
        self.assert_rejected(self.resolve(link / 'child'))

    def cmake(self, path, resolver_dir=None):
        source = (ROOT / 'plugins/rust_api/cargokit/cmake/cargokit.cmake').read_text(encoding='utf-8')
        a = source.index('    execute_process('); b = source.index('\nendif()', a)
        block = source[a:b].replace('COMMAND powershell',
                                   'COMMAND ' + cmake_literal(Path(POWERSHELL).as_posix()))
        script = self.root / 'probe.cmake'
        output = self.root / 'result.txt'
        output.unlink(missing_ok=True)  # No stale success file may hide continuation.
        prefix = 'set(CMAKE_CURRENT_LIST_DIR ' + cmake_literal((resolver_dir or RESOLVER.parent).as_posix()) + ')\n'
        script.write_bytes((prefix + 'set(cargokit_cmake_root ' + cmake_literal(path.as_posix()) + ')\n' + block +
            '\nfile(WRITE ' + cmake_literal(output.as_posix()) + ' "${cargokit_cmake_root}")\n').encode('utf-8'))
        result = subprocess.run(['cmake', '-P', str(script)], capture_output=True, timeout=40)
        return result, output

    def test_real_cmake_boundary_and_failure_stop(self):
        link = self.link('cmake-alias', self.directory)
        inputs = [self.directory, self.directory.resolve(strict=True), link]
        if os.name == 'nt':
            inputs.append(self.windows_short_path(self.root) / self.directory.name)
        for path in inputs:
            with self.subTest(valid=path):
                result, output = self.cmake(path)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_bytes(), self.directory.resolve(strict=True).as_posix().encode('utf-8'))
        file = self.directory / 'file.txt'; file.write_bytes(b'file')
        for path in [*self.missing_paths(), link / 'missing', file, file / 'child']:
            with self.subTest(invalid=path):
                result, output = self.cmake(path)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Cargokit path resolution failed', result.stderr)
                self.assertFalse(output.exists(), 'CMake continued after failed path resolution')

    def test_real_cmake_rejects_error_status_and_nonexistent_output(self):
        fake = self.root / 'fake-resolver'; fake.mkdir()
        for valid_output, code in ((True, 1), (False, 0)):
            with self.subTest(valid_output=valid_output, code=code):
                # Controlled faulty producer; the actual CMake consumer must
                # independently check both status and directory existence.
                suffix = '' if valid_output else '/missing'
                (fake / RESOLVER.name).write_bytes((
                    '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)\n'
                    '[Console]::Out.Write($args[0].Replace("\\", "/") + "' + suffix + '")\n'
                    'exit ' + str(code) + '\n').encode('utf-8'))
                result, output = self.cmake(self.directory, fake)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Cargokit path resolution failed', result.stderr)
                self.assertFalse(output.exists())


if __name__ == '__main__':
    if not POWERSHELL or not shutil.which('cmake'):
        raise SystemExit('PowerShell and CMake are required')
    unittest.main()
