"""Real Git/CLI regressions for #105, with no Dart, network or app build."""
from __future__ import annotations

import ast
from contextlib import chdir, contextmanager
import ntpath
import hashlib
import importlib.util
import io
import os
import errno
import stat
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('context_packager', ROOT / 'tool/prepare_linux_packager.py')
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)
SOURCE = ROOT / '.local-build/tool-sources/flutter_distributor' / PACKAGER.PINNED_REVISION


def command(args, **kwargs):
    return subprocess.run([str(x) for x in args], capture_output=True, check=True,
                          timeout=60, **kwargs)


class PackagerContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Missing pinned input is a failure, not a successful CI skip.
        cls.archive = PACKAGER.git(SOURCE, 'archive', PACKAGER.PINNED_REVISION,
                                   'packages', 'LICENSE', 'README.md')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='packager-context-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'checkout'
        command(['git', 'init', '--quiet', '--template=', self.repo])
        (self.repo / '.gitignore').write_text('build/\n', encoding='utf-8')
        command(['git', 'add', '.gitignore'], cwd=self.repo)
        self.index = (self.repo / '.git/index').read_bytes()
        self.config = (self.repo / '.git/config').read_bytes()

    def stage(self, parent, name):
        destination = parent / name
        destination.mkdir(parents=True)
        PACKAGER.export_tool_archive(self.archive, destination)
        return destination

    def mixed_patch(self):
        # Real Git-style headers on all targets reproduce the formerly skipped
        # paths without depending on whatever patch serialization we ship next.
        lines = []
        for line in PACKAGER.PATCH.read_text(encoding='utf-8').splitlines(True):
            if line.startswith('diff --git '):
                continue
            if line.startswith('--- a/'):
                name = line.strip()[6:]
                lines.append(f'diff --git a/{name} b/{name}\n')
            lines.append(line)
        patch = self.root / 'git-format.patch'
        # A temporary patch is not protected by checkout .gitattributes.
        # Write exact UTF-8/LF bytes on Windows as well as POSIX.
        patch.write_bytes(''.join(lines).encode('utf-8'))
        return patch

    def test_generated_patch_ignores_windows_text_newline_default(self):
        write_text = Path.write_text
        def windows_write(path, data, *args, **kwargs):
            kwargs.setdefault('newline', '\r\n')
            return write_text(path, data, *args, **kwargs)
        with mock.patch.object(Path, 'write_text', windows_write):
            patch = self.mixed_patch()
        self.assertNotIn(b'\r', patch.read_bytes())
        for parent in (self.root / 'outside', self.repo / 'build'):
            with self.subTest(parent=parent):
                stage = self.stage(parent, 'fixed-newlines')
                PACKAGER.apply_tool_patch(stage, patch)
                self.assert_complete(stage)

    def test_old_crlf_patch_is_rejected_without_relaxing_checks(self):
        correct = self.mixed_patch().read_bytes()
        old = self.root / 'old-windows.patch'
        old.write_text(correct.decode('utf-8'), encoding='utf-8', newline='\r\n')
        self.assertIn(b'\r\n', old.read_bytes())
        for parent in (self.root / 'outside', self.repo / 'build'):
            with self.subTest(parent=parent):
                stage = self.stage(parent, 'old-newlines')
                with self.assertRaisesRegex(RuntimeError, 'patch rejected'):
                    PACKAGER.apply_tool_patch(stage, old)
                PACKAGER.verify_hashes(stage, 0)
                self.assertFalse((stage / '.git').exists())

    def assert_complete(self, path):
        PACKAGER.verify_hashes(path, 1)
        self.assertFalse((path / '.git').exists())
        self.assertEqual((self.repo / '.git/index').read_bytes(), self.index)
        self.assertEqual((self.repo / '.git/config').read_bytes(), self.config)

    def test_patch_inside_outside_and_inherited_git_environment(self):
        for parent in (self.root / 'outside', self.repo / 'build'):
            for patch in (PACKAGER.PATCH, self.mixed_patch()):
                with self.subTest(parent=parent, patch=patch.name):
                    stage = self.stage(parent, patch.stem)
                    with mock.patch.dict(os.environ, {
                        'GIT_DIR': str(self.repo / '.git'),
                        'GIT_WORK_TREE': str(self.repo),
                        'GIT_INDEX_FILE': str(self.repo / '.git/index'),
                    }):
                        PACKAGER.apply_tool_patch(stage, patch)
                    self.assert_complete(stage)

    def test_old_apply_returns_zero_but_skips_git_headers_inside_repo(self):
        stage = self.stage(self.repo / 'build', 'old-context')
        result = command(['git', '-c', 'core.autocrlf=false', 'apply', '--verbose',
                          self.mixed_patch()], cwd=stage)
        self.assertIn(b'Skipped patch', result.stderr)
        # Exit zero alone was the false positive. Actual bytes stay unpatched.
        PACKAGER.verify_hashes(stage, 0)
        with self.assertRaisesRegex(RuntimeError, 'Patched source drift'):
            PACKAGER.verify_hashes(stage, 1)

    def test_failure_cleans_git_metadata_and_never_touches_parent_index(self):
        stage = self.stage(self.repo / 'build', 'failed')
        broken = self.root / 'bad.patch'
        broken.write_text('not a valid patch\n', encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'patch rejected'):
            PACKAGER.apply_tool_patch(stage, broken)
        self.assertFalse((stage / '.git').exists())
        PACKAGER.verify_hashes(stage, 0)
        self.assertEqual((self.repo / '.git/index').read_bytes(), self.index)

    def test_existing_git_metadata_is_rejected_and_preserved(self):
        stage = self.stage(self.repo / 'build', 'already-a-repository')
        command(['git', 'init', '--quiet', '--template=', stage])
        before = (stage / '.git/config').read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'already contains Git metadata'):
            PACKAGER.apply_tool_patch(stage, PACKAGER.PATCH)
        self.assertEqual((stage / '.git/config').read_bytes(), before)
        PACKAGER.verify_hashes(stage, 0)

    def test_default_cli_with_shallow_source_like_matrix_setup(self):
        shallow = self.root / 'shallow-source'
        command(['git', 'clone', '--quiet', '--depth', '1', '--no-local', SOURCE.as_uri(), shallow])
        self.assertEqual(command(['git', 'rev-parse', '--is-shallow-repository'], cwd=shallow).stdout.strip(), b'true')
        with mock.patch(__name__ + '.SOURCE', shallow):
            self.test_real_cli_default_output_and_external_output_are_identical()

    def test_real_archive_and_default_cli_ignore_host_line_endings(self):
        git_dir = Path(command(['git', '-C', SOURCE, 'rev-parse', '--absolute-git-dir']).stdout.decode().strip())
        originals = [git_dir / 'config', git_dir / 'index', *sorted((git_dir / 'objects/pack').glob('*'))]
        def snapshot():
            return {str(path): (path.stat().st_mode, getattr(path.stat(), 'st_file_attributes', 0),
                               hashlib.sha256(path.read_bytes()).hexdigest())
                    for path in originals if path.is_file()}
        before = snapshot()
        snapshots = []
        for mode in ('false', 'input', 'true'):
            with self.subTest(autocrlf=mode):
                # Each case owns a complete fresh repository. No mid-test raw
                # rmtree of Git's read-only objects, and no reused Git index.
                with tempfile.TemporaryDirectory(prefix='packager-eol-') as temporary:
                    case = Path(temporary).resolve()
                    repo = case / 'checkout'
                    command(['git', 'init', '--quiet', '--template=', repo])
                    tools = self.install_cli_fixture(repo=repo, autocrlf=mode)
                    source = repo / '.local-build/tool-sources/flutter_distributor' / PACKAGER.PINNED_REVISION
                    output = repo / 'build/packaging-tools/flutter_distributor'
                    index = (repo / '.git/index').read_bytes()
                    config = (repo / '.git/config').read_bytes()
                    # File transport makes real pack files without sharing their
                    # inode/attributes with SOURCE. Never chmod a shared object.
                    self.assertFalse((source / '.git/objects/info/alternates').exists())
                    indexes = list((source / '.git/objects/pack').glob('*.idx'))
                    self.assertTrue(indexes, 'fixture must contain real Git pack indexes')
                    for idx in indexes:
                        command(['git', '-C', source, 'verify-pack', '-s', idx])
                        for path in (idx, idx.with_suffix('.pack')):
                            path.chmod(stat.S_IREAD)
                            self.assertFalse(path.stat().st_mode & stat.S_IWUSR)
                            if os.name == 'nt':
                                self.assertTrue(path.stat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY)
                    plain = case / 'ordinary-readonly.txt'
                    plain.write_bytes(b'owned temporary fixture'); plain.chmod(stat.S_IREAD)
                    self.assertEqual(command(['git', 'status', '--porcelain'], cwd=source).stdout, b'')
                    if mode == 'true':
                        self.assertIn(b'\r\n', (source / next(iter(PACKAGER.SOURCE_HASHES))).read_bytes())
                    command([sys.executable, tools / 'prepare_linux_packager.py'], cwd=repo)
                    self.assert_complete(output)
                    self.assertEqual((repo / '.git/index').read_bytes(), index)
                    self.assertEqual((repo / '.git/config').read_bytes(), config)
                    snapshots.append({name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                                      for name in PACKAGER.SOURCE_HASHES})
                    if mode == 'true':
                        # The old archive invocation still fails exact hashes.
                        old = command(['git', '-C', source, 'archive', PACKAGER.PINNED_REVISION,
                                       'packages', 'LICENSE', 'README.md']).stdout
                        stage = case / 'old-archive'; stage.mkdir()
                        PACKAGER.export_tool_archive(old, stage)
                        with self.assertRaisesRegex(RuntimeError, 'Upstream source drift'):
                            PACKAGER.verify_hashes(stage, 0)
                        name = next(iter(PACKAGER.SOURCE_HASHES))
                        self.assertIn(b'\r\n', (stage / name).read_bytes())
                        self.assertEqual(hashlib.sha256((stage / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
                                         PACKAGER.SOURCE_HASHES[name][0])
                self.assertFalse(case.exists(), 'TemporaryDirectory must remove read-only files')
                self.assertEqual(snapshot(), before, 'SOURCE object bytes/permissions/index/config changed')
        self.assertEqual(snapshots, [snapshots[0]] * 3)

    def install_cli_fixture(self, *, repo=None, autocrlf=None):
        # An actual enclosing repository, tracked gitlink and source checkout,
        # rather than calling prepare() in a repository-external temp directory.
        repo = repo or self.repo
        tools = repo / 'tool'
        (tools / 'patches').mkdir(parents=True)
        shutil.copyfile(ROOT / 'tool/prepare_linux_packager.py', tools / 'prepare_linux_packager.py')
        for dependency in ('checkout_distributor.py','pub_get_retry.py','owned_process_cleanup.py'):
            shutil.copyfile(ROOT/'tool'/dependency,tools/dependency)
        shutil.copyfile(PACKAGER.PATCH, tools / 'patches' / PACKAGER.PATCH.name)
        source = repo / '.local-build/tool-sources/flutter_distributor' / PACKAGER.PINNED_REVISION
        source.parent.mkdir(parents=True)
        if autocrlf is None:
            command(['git', 'clone', '--quiet', '--shared', '--no-checkout', SOURCE, source])
        else:
            command(['git', 'clone', '--quiet', '--no-local', '--no-checkout', SOURCE.as_uri(), source])
            command(['git', 'config', 'core.autocrlf', autocrlf], cwd=source)
            command(['git', 'config', 'core.eol', 'crlf'], cwd=source)
        command(['git', 'checkout', '--quiet', '--detach', PACKAGER.PINNED_REVISION], cwd=source)
        # Track fixture tools so the parent index exists without a gitlink.
        command(['git', 'add', 'tool'], cwd=repo)
        if repo == self.repo:
            self.index = (repo / '.git/index').read_bytes()
        return tools

    def test_real_cli_default_output_and_external_output_are_identical(self):
        tools = self.install_cli_fixture()
        snapshots = []
        for extra, output in (([], self.repo / 'build/packaging-tools/flutter_distributor'),
                              (['--output', str(self.root / 'external')], self.root / 'external')):
            command([sys.executable, tools / 'prepare_linux_packager.py', *extra], cwd=self.repo)
            self.assert_complete(output)
            snapshots.append({name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                              for name in PACKAGER.SOURCE_HASHES})
        self.assertEqual(snapshots[0], snapshots[1])
        default = self.repo / 'build/packaging-tools/flutter_distributor'
        (default / 'stale').write_text('old', encoding='utf-8')
        command([sys.executable, tools / 'prepare_linux_packager.py'], cwd=self.repo)
        self.assert_complete(default)
        self.assertFalse((default / 'stale').exists())
        # Exact CLI default path fails closed and preserves the previous good tree.
        patch = tools / 'patches' / PACKAGER.PATCH.name
        patch.write_bytes(patch.read_bytes() + b'\nchanged\n')
        result = subprocess.run([sys.executable, str(tools / 'prepare_linux_packager.py')],
                                cwd=self.repo, capture_output=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'patch drift', result.stderr)
        self.assert_complete(default)

    def test_real_cli_success_log_is_ascii_safe_without_hiding_failure(self):
        tools = self.install_cli_fixture()
        for path_kind in ('ascii', 'chinese'):
            if path_kind == 'chinese':
                destination = self.root / '中文 工作区'
                self.repo.rename(destination)
                self.repo = destination
                tools = self.repo / 'tool'
            output = self.repo / 'build/packaging-tools/flutter_distributor'
            for encoding in ('utf-8', 'cp1252'):
                with self.subTest(path_kind=path_kind, encoding=encoding):
                    env = {**os.environ, 'PYTHONIOENCODING': encoding + ':strict'}
                    result = command([sys.executable, tools / 'prepare_linux_packager.py'],
                                     cwd=self.repo, env=env)
                    # Real captured stdout, not a fake print/TextIO wrapper.
                    line = result.stdout.decode('ascii').strip()
                    self.assertTrue(line.startswith('Prepared packager: '), line)
                    logged_path = ast.literal_eval(line.removeprefix('Prepared packager: '))
                    self.assertEqual(logged_path, str(output.resolve() / 'packages/flutter_distributor'))
                    self.assert_complete(output)

        # Retain the previous implementation in a temporary copy as a negative
        # control. Only its final diagnostic changes; all real preparation runs.
        source = (tools / 'prepare_linux_packager.py').read_text(encoding='utf-8')
        current = 'print(f"Prepared packager: {str(output / \'packages/flutter_distributor\')!a}")'
        legacy = 'print(f"Prepared packager: {output / \'packages/flutter_distributor\'}")'
        self.assertEqual(source.count(current), 1)
        old_cli = tools / 'legacy_prepare.py'
        old_cli.write_text(source.replace(current, legacy), encoding='utf-8', newline='\n')
        for encoding in ('utf-8', 'cp1252'):
            env = {**os.environ, 'PYTHONIOENCODING': encoding + ':strict'}
            result = subprocess.run([sys.executable, str(old_cli)], cwd=self.repo,
                                    env=env, capture_output=True, timeout=60)
            self.assertEqual(result.returncode == 0, encoding == 'utf-8')
            if encoding == 'cp1252':
                self.assertIn(b'UnicodeEncodeError', result.stderr)
            self.assert_complete(output)

        # A real bad patch must still fail, print no success, and leave the
        # previous verified output intact under either output codepage.
        patch = tools / 'patches' / PACKAGER.PATCH.name
        patch.write_bytes(patch.read_bytes() + b'\ninvalid\n')
        for encoding in ('utf-8', 'cp1252'):
            env = {**os.environ, 'PYTHONIOENCODING': encoding + ':strict'}
            result = subprocess.run([sys.executable, str(tools / 'prepare_linux_packager.py')],
                                    cwd=self.repo, env=env, capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'patch drift', result.stderr)
            self.assertNotIn(b'Prepared packager:', result.stdout)
            self.assert_complete(output)


@contextmanager
def windows_readonly_semantics():
    """On POSIX replay only Windows' read-only unlink rule; native Windows is real."""
    if os.name == 'nt':
        yield
        return
    unlink = os.unlink
    def checked(path, *args, **kwargs):
        info = os.stat(path, dir_fd=kwargs.get('dir_fd'), follow_symlinks=False)
        if not info.st_mode & stat.S_IWUSR:
            raise PermissionError(errno.EACCES, 'fixture read-only file', str(path))
        return unlink(path, *args, **kwargs)
    with mock.patch.object(os, 'unlink', side_effect=checked):
        yield


class TemporaryGitCleanupTests(unittest.TestCase):
    def test_raw_rmtree_negative_and_temporary_directory_positive(self):
        temporary = tempfile.TemporaryDirectory(prefix='readonly-cleanup-')
        root = Path(temporary.name)
        file = root / 'ordinary-readonly.txt'
        file.write_bytes(b'keep until controlled cleanup'); file.chmod(stat.S_IREAD)
        try:
            # Native Windows reproduces WinError 5. Linux exercises the same
            # handler via an explicitly labelled unlink-rule control, not chmod alone.
            with windows_readonly_semantics():
                with self.assertRaises(PermissionError): shutil.rmtree(root)
                self.assertEqual(file.read_bytes(), b'keep until controlled cleanup')
                temporary.cleanup()
            self.assertFalse(root.exists())
        finally:
            temporary.cleanup()

    def test_real_cleanup_errors_are_not_ignored(self):
        temporary = tempfile.TemporaryDirectory(prefix='cleanup-error-')
        root = Path(temporary.name)
        root.rmdir(); root.write_bytes(b'not a directory')
        try:
            with self.assertRaises(OSError): temporary.cleanup()
            self.assertEqual(root.read_bytes(), b'not a directory')
        finally:
            root.unlink(); temporary.cleanup()

        if os.name == 'nt':
            self.assert_windows_locked_file_cannot_be_removed()

    def assert_windows_locked_file_cannot_be_removed(self):
        # Real Windows sharing violation: deny FILE_SHARE_DELETE until close.
        # POSIX uses the real non-directory error above; do not replace global
        # os.unlink with a permanent denial inside tempfile/shutil internals.
        import ctypes
        from ctypes import wintypes
        temporary = tempfile.TemporaryDirectory(prefix='cleanup-denied-')
        self.addCleanup(temporary.cleanup)
        with temporary as directory:
            root = Path(directory); file = root / 'held.txt'; file.write_bytes(b'held')
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.argtypes = [wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,
                                          wintypes.LPVOID,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
            kernel.CreateFileW.restype = wintypes.HANDLE
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]; kernel.CloseHandle.restype = wintypes.BOOL
            handle = kernel.CreateFileW(str(file), 0x80000000, 1, None, 3, 0x80, None)
            self.assertNotEqual(handle, ctypes.c_void_p(-1).value, 'Cannot create native locked-file control')
            try:
                with self.assertRaises(PermissionError): temporary.cleanup()
                self.assertEqual(file.read_bytes(), b'held')
            finally:
                kernel.CloseHandle(handle)
        self.assertFalse(root.exists())


class ArchiveAliasTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='archive-alias-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.real = self.root / 'real'
        self.real.mkdir()
        self.alias = self.root / 'alias'
        if os.name == 'nt':
            command(['cmd', '/d', '/c', 'mklink', '/J', self.alias, self.real])
            # Junction removal must not recursively delete the referenced tree.
            self.addCleanup(lambda: os.rmdir(self.alias) if self.alias.exists() else None)
        else:
            self.alias.symlink_to(self.real, target_is_directory=True)

    def archive(self, entries):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            for name, content, link in entries:
                member = tarfile.TarInfo(name)
                if link:
                    member.type = tarfile.SYMTYPE
                    member.linkname = content
                    archive.addfile(member)
                else:
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
        return data.getvalue()

    def test_alias_root_and_relative_root_keep_valid_file_links(self):
        archive = self.archive([('README.md', b'content', False),
                                ('packages/tool/README.md', '../../README.md', True)])
        # Both export modes share the canonical root contract. Windows native
        # symlink creation is deliberately not required (materialize=True).
        modes = (True,) if os.name == 'nt' else (True, False)
        for relative in (False, True):
            for materialize in modes:
                with self.subTest(relative=relative, materialize=materialize):
                    stage = self.alias / f'{relative}-{materialize}'
                    stage.mkdir()
                    # TEMP may be on C: while the checkout is on D:. Relative
                    # paths must be formed and consumed on the same volume.
                    with chdir(self.root):
                        argument = stage.relative_to(self.root) if relative else stage
                        PACKAGER.export_tool_archive(archive, argument, materialize_links=materialize)
                    self.assertEqual((stage / 'packages/tool/README.md').read_bytes(), b'content')
                    self.assertEqual((stage / 'packages/tool/README.md').is_symlink(), not materialize)

    def test_windows_cross_volume_relative_path_is_not_a_valid_fixture(self):
        with self.assertRaises(ValueError):
            ntpath.relpath(r'C:\Temp\stage', r'D:\a\checkout')
        self.assertEqual(ntpath.relpath(r'C:\Temp\stage', r'C:\Temp'), 'stage')

    def test_old_mixed_path_comparison_rejects_a_valid_alias(self):
        target = self.alias / 'README.md'
        target.write_bytes(b'content')
        self.assertFalse(target.resolve().is_relative_to(self.alias))
        self.assertTrue(target.resolve().is_relative_to(self.alias.resolve()))

    def test_real_escape_dangling_and_cycles_remain_rejected_under_alias(self):
        outside = self.root / 'outside'
        outside.write_bytes(b'unchanged')
        cases = {
            'escape': [('link', '../../outside', True)],
            'dangling': [('link', 'missing', True)],
            'cycle': [('one', 'two', True), ('two', 'one', True)],
        }
        modes = (True,) if os.name == 'nt' else (True, False)
        for name, entries in cases.items():
            for materialize in modes:
                with self.subTest(name=name, materialize=materialize):
                    stage = self.alias / f'{name}-{materialize}'
                    stage.mkdir()
                    with self.assertRaisesRegex(RuntimeError, 'Unsafe tool archive link'):
                        PACKAGER.export_tool_archive(self.archive(entries), stage,
                                                     materialize_links=materialize)
                    self.assertEqual(outside.read_bytes(), b'unchanged')


if __name__ == '__main__':
    unittest.main()
