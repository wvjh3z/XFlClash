"""Offline regression of the pinned patch and the actual Dart AppImage maker.

Fake ldd/locate/appimagetool operate on synthetic ELF files; cp is the real system cp.
No pub get, Flutter/client/core compilation, or network operations are run.
The real-ldd cases compile tiny public C fixtures on an authorized build host.
CI sets LINUX_PACKAGER_REQUIRE_DART=1 to make missing prerequisites a failure.
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from distributor_graph import resolved_packages


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("prepare_linux_packager", REPO / "tool/prepare_linux_packager.py")
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)
SOURCE = REPO / ".local-build/tool-sources/flutter_distributor" / "cdeeef2d8f8325bb6ae0bc86b39f56e4325d1a58"
FIXTURE = REPO / "tool/test/fixtures/linux_appimage_maker.dart"


def is_shell_parent(executable, comm, argv):
    """Identify the actual shell, including binfmt's explicit QEMU interpreter."""
    shells = {'dash', 'sh', 'bash'}
    if comm not in shells or not argv:
        return False
    if Path(executable).name in shells:
        return len(argv) >= 2 and Path(argv[0]).name in shells and argv[1] == '-c'
    return (Path(executable).name == 'qemu-aarch64' and len(argv) >= 3
            and argv[0] == executable and Path(argv[1]).name in shells
            and argv[2] == '-c')


class ShellParentIdentityTests(unittest.TestCase):
    def test_native_and_explicit_emulated_shell(self):
        self.assertTrue(is_shell_parent('/usr/bin/dash', 'sh', ['sh', '-c', 'fixture']))
        self.assertTrue(is_shell_parent('/tools/qemu-aarch64', 'sh',
                        ['/tools/qemu-aarch64', '/usr/bin/sh', '-c', 'fixture']))

    def test_interpreter_name_alone_cannot_hide_a_non_shell_parent(self):
        for executable, comm, argv in [
            ('/tools/qemu-aarch64', 'sh', ['/tools/qemu-aarch64', '/usr/bin/python3', '-c', 'fixture']),
            ('/tools/qemu-aarch64', 'sh', ['/different/qemu-aarch64', '/bin/sh', '-c', 'fixture']),
            ('/tools/qemu-aarch64', 'python3', ['/tools/qemu-aarch64', '/bin/sh', '-c', 'fixture']),
            ('/tools/qemu-aarch64', 'sh', ['/tools/qemu-aarch64', '/bin/sh', 'fixture']),
            ('/tools/python3', 'sh', ['sh', '-c', 'fixture']),
            ('/usr/bin/dash', 'sh', ['python3', '-c', 'fixture']),
        ]:
            with self.subTest(argv=argv):
                self.assertFalse(is_shell_parent(executable, comm, argv))


def command(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=60, **kwargs)


def package_configuration(output: Path, tools: Path) -> Path:
    """Use the activated graph only, then let the fixture remap its isolated sources."""
    prepared = tools / 'packages'
    config = Path(os.environ.get('LINUX_PACKAGER_PACKAGE_CONFIG',
                                str(prepared / 'flutter_distributor/.dart_tool/package_config.json')))
    packages = resolved_packages(config, prepared=prepared)
    output.write_text(json.dumps({'configVersion': 2, 'packages': list(packages.values())}), encoding='utf-8')
    return output


class PrepareLinuxPackagerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xfl-packager-prepare-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "tools"

    def test_repeat_preparation_is_clean_and_idempotent(self):
        before = PACKAGER.git(SOURCE, "status", "--porcelain")
        PACKAGER.prepare(SOURCE, self.output)
        snapshot = {p.relative_to(self.output): p.read_bytes() for p in self.output.rglob("*") if p.is_file()}
        (self.output / "untrusted-stale-file").write_text("stale")
        PACKAGER.prepare(SOURCE, self.output)
        self.assertEqual(snapshot, {p.relative_to(self.output): p.read_bytes() for p in self.output.rglob("*") if p.is_file()})
        self.assertEqual(before, PACKAGER.git(SOURCE, "status", "--porcelain"))
        self.assertTrue((self.output / "LICENSE").is_file())
        self.assertFalse(list(self.output.rglob(".git")))
        self.assertFalse(list(self.output.rglob(".dart_tool")))

    def test_preparation_preserves_real_relative_readme_links_without_data_filter(self):
        # Python 3.10.12's filter incorrectly resolves this link from the
        # extraction root instead of packages/flutter_distributor. The complete
        # preparation must keep the link and still apply all pinned hashes.
        with mock.patch.object(PACKAGER.tarfile, "data_filter", create=True,
                               side_effect=AssertionError("version-dependent data_filter called")):
            PACKAGER.prepare(SOURCE, self.output)
        link = self.output / "packages/flutter_distributor/README.md"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "../../README.md")
        self.assertEqual(link.resolve(), self.output / "README.md")
        self.assertEqual(link.read_bytes(), (SOURCE / "README.md").read_bytes())
        PACKAGER.verify_hashes(self.output, 1)

    def archive(self, *entries):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as contents:
            for name, kind, value, *mode in entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.mode = mode[0] if mode else 0o7777
                if kind == tarfile.REGTYPE:
                    member.size = len(value)
                    contents.addfile(member, io.BytesIO(value))
                else:
                    member.linkname = value
                    contents.addfile(member)
        return archive.getvalue()

    def test_export_preserves_internal_links_and_git_executable_bit(self):
        staged = self.root / "staged"
        staged.mkdir()
        # The directory link's target deliberately appears later in the tar.
        archive = self.archive(
            ("packages/docs", tarfile.SYMTYPE, "../docs"),
            ("packages/readme", tarfile.SYMTYPE, "docs/README.md"),
            ("docs/README.md", tarfile.REGTYPE, b"linked content"),
            ("bin/tool", tarfile.REGTYPE, b"#!/bin/sh\n"),
            ("docs/plain", tarfile.REGTYPE, b"ordinary", 0o666),
        )
        PACKAGER.export_tool_archive(archive, staged)
        self.assertEqual((staged / "packages/readme").read_bytes(), b"linked content")
        self.assertTrue((staged / "packages/docs").is_symlink())
        self.assertEqual((staged / "bin/tool").stat().st_mode & 0o7777, 0o755)
        self.assertEqual((staged / "docs/plain").stat().st_mode & 0o7777, 0o644)

    def test_unsafe_archives_do_not_replace_complete_output_or_write_outside(self):
        PACKAGER.prepare(SOURCE, self.output)
        sentinel = self.output / "complete"
        sentinel.write_text("preserve")
        outside = self.root / "outside"
        outside.write_text("untouched")
        cases = {
            "absolute member": ((str(outside), tarfile.REGTYPE, b"overwrite"),),
            "parent traversal": (("../../outside", tarfile.REGTYPE, b"overwrite"),),
            "absolute link": (("packages/link", tarfile.SYMTYPE, str(outside)),),
            "escaping relative link": (("packages/link", tarfile.SYMTYPE, "../../../outside"),),
            "dangling internal link": (("packages/link", tarfile.SYMTYPE, "missing"),),
            "hard link": (("hard", tarfile.LNKTYPE, str(outside)),),
            "fifo": (("pipe", tarfile.FIFOTYPE, ""),),
            "character device": (("device", tarfile.CHRTYPE, ""),),
            "block device": (("device", tarfile.BLKTYPE, ""),),
            "duplicate link": (
                ("link", tarfile.SYMTYPE, "README.md"),
                ("link", tarfile.SYMTYPE, "../outside"),
            ),
            "duplicate file": (
                ("README.md", tarfile.REGTYPE, b"first"),
                ("README.md", tarfile.REGTYPE, b"second"),
            ),
            "file under link": (
                ("packages/dir", tarfile.SYMTYPE, "../.."),
                ("packages/dir/outside", tarfile.REGTYPE, b"overwrite"),
            ),
            "link under link": (
                ("packages/dir", tarfile.SYMTYPE, "../.."),
                ("packages/dir/link", tarfile.SYMTYPE, "outside"),
            ),
            "file as parent": (
                ("packages/file", tarfile.REGTYPE, b"file"),
                ("packages/file/child", tarfile.REGTYPE, b"child"),
            ),
            "link cycle": (
                ("first", tarfile.SYMTYPE, "second"),
                ("second", tarfile.SYMTYPE, "first"),
            ),
        }
        # Every direct target looks contained before following the links.
        # Collapsing next/another changes first's '..' segments to reach the
        # existing outside sentinel, so this tests containment, not absence.
        chain = (
            ("packages/first", tarfile.SYMTYPE, "next/another/../../../outside"),
            ("packages/next", tarfile.SYMTYPE, "."),
            ("packages/another", tarfile.SYMTYPE, "."),
        )
        cases["link chain escape"] = chain
        cases["reversed link chain escape"] = tuple(reversed(chain))
        original_git = PACKAGER.git
        for name, entries in cases.items():
            with self.subTest(archive=name):
                archive = self.archive(*entries)

                def fixture_git(source, *arguments):
                    if arguments[0] == "archive":
                        return archive
                    return original_git(source, *arguments)

                with mock.patch.object(PACKAGER, "git", side_effect=fixture_git):
                    with self.assertRaisesRegex(RuntimeError, "Unsafe tool archive"):
                        PACKAGER.prepare(SOURCE, self.output)
                self.assertEqual(sentinel.read_text(), "preserve")
                self.assertEqual(outside.read_text(), "untouched")
                PACKAGER.verify_hashes(self.output, 1)
                self.assertFalse(list(self.root.glob(".prepare-linux-packager-*")))

    def test_changed_patch_does_not_replace_complete_output(self):
        PACKAGER.prepare(SOURCE, self.output)
        sentinel = self.output / "complete"
        sentinel.write_text("preserve")
        patch = self.root / "bad.patch"
        patch.write_text(PACKAGER.PATCH.read_text().replace("'ARCH': appImageArch", "'ARCH': 'wrong'"))
        with self.assertRaisesRegex(RuntimeError, "patch drift"):
            PACKAGER.prepare(SOURCE, self.output, patch)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertFalse(list(self.root.glob(".prepare-linux-packager-*")))

    def test_patch_cannot_be_applied_twice(self):
        PACKAGER.prepare(SOURCE, self.output)
        process = subprocess.run(["git", "apply", "--check", str(PACKAGER.PATCH)], cwd=self.output, capture_output=True)
        self.assertNotEqual(process.returncode, 0)

    def test_tracked_source_drift_is_rejected(self):
        clone = self.root / "source"
        command("git", "clone", "--quiet", "--shared", "--no-hardlinks", str(SOURCE), str(clone))
        (clone / next(iter(PACKAGER.SOURCE_HASHES))).write_text("changed upstream")
        with self.assertRaisesRegex(RuntimeError, "source drift"):
            PACKAGER.prepare(clone, self.output)
        self.assertFalse(self.output.exists())

    def test_wrong_revision_is_rejected(self):
        self.assert_wrong_revision_is_rejected(shallow=False)

    def test_wrong_revision_is_rejected_in_shallow_clone(self):
        self.assert_wrong_revision_is_rejected(shallow=True)

    def commit_tree(self, source, tree, *parents):
        env = dict(
            os.environ,
            GIT_AUTHOR_NAME="Packager test", GIT_AUTHOR_EMAIL="packager-test@example.invalid",
            GIT_COMMITTER_NAME="Packager test", GIT_COMMITTER_EMAIL="packager-test@example.invalid",
            GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000",
            GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000",
        )
        return command(
            "git", "-C", str(source), "commit-tree", tree, *parents,
            "-m", "Local revision fixture", env=env,
        ).stdout.strip()

    def assert_wrong_revision_is_rejected(self, *, shallow):
        # A local two-commit seed gives a real full-history case even when the
        # checkout's distributor submodule is itself shallow, as it is in CI.
        seed = self.root / "seed"
        command("git", "init", "--quiet", "--initial-branch=fixture", str(seed))
        tree = command("git", "-C", str(seed), "mktree", input="").stdout.strip()
        first = self.commit_tree(seed, tree)
        second = self.commit_tree(seed, tree, "-p", first)
        command("git", "-C", str(seed), "update-ref", "refs/heads/fixture", second)
        clone = self.root / "source"
        # file:// forces transport cloning, so --depth is actually honored.
        depth = ["--depth=1"] if shallow else []
        command("git", "clone", "--quiet", *depth, seed.as_uri(), str(clone))
        self.assertEqual(PACKAGER.git(clone, "rev-parse", "--is-shallow-repository").strip(), b"true" if shallow else b"false")
        self.assertEqual(PACKAGER.git(clone, "rev-list", "--count", "HEAD").strip(), b"1" if shallow else b"2")
        # Manufacture an unknown revision without asking for an upstream parent.
        revision = self.commit_tree(clone, "HEAD^{tree}", "-p", "HEAD")
        command("git", "-C", str(clone), "checkout", "--quiet", "--detach", revision)
        self.assertNotEqual(PACKAGER.git(clone, "rev-parse", "HEAD").decode().strip(), PACKAGER.PINNED_REVISION)
        with self.assertRaisesRegex(RuntimeError, "Unexpected distributor revision"):
            PACKAGER.prepare(clone, self.output)
        self.assertFalse(self.output.exists())

    def test_pinned_revision_prepares_in_shallow_clone(self):
        original_revision = PACKAGER.git(SOURCE, "rev-parse", "HEAD")
        original_status = PACKAGER.git(SOURCE, "status", "--porcelain")
        PACKAGER.verify_hashes(SOURCE, 0)
        clone = self.root / "source"
        command("git", "clone", "--quiet", "--depth=1", SOURCE.as_uri(), str(clone))
        self.assertEqual(PACKAGER.git(clone, "rev-parse", "--is-shallow-repository").strip(), b"true")
        self.assertEqual(PACKAGER.git(clone, "rev-list", "--count", "HEAD").strip(), b"1")
        self.assertEqual(PACKAGER.git(clone, "rev-parse", "HEAD").decode().strip(), PACKAGER.PINNED_REVISION)
        PACKAGER.verify_hashes(clone, 0)
        PACKAGER.prepare(clone, self.output)
        PACKAGER.verify_hashes(self.output, 1)
        PACKAGER.verify_hashes(clone, 0)
        self.assertEqual(PACKAGER.git(clone, "rev-parse", "HEAD"), original_revision)
        self.assertEqual(PACKAGER.git(clone, "status", "--porcelain"), b"")
        PACKAGER.verify_hashes(SOURCE, 0)
        self.assertEqual(PACKAGER.git(SOURCE, "rev-parse", "HEAD"), original_revision)
        self.assertEqual(PACKAGER.git(SOURCE, "status", "--porcelain"), original_status)

    def test_output_parent_symlink_cannot_pollute_source(self):
        alias = self.root / "source_alias"
        alias.symlink_to(SOURCE, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "separate from the source"):
            PACKAGER.prepare(SOURCE, alias / "must-not-exist")
        self.assertFalse((SOURCE / "must-not-exist").exists())


class LocalDesktopArchitectureGuardTest(unittest.TestCase):
    def test_real_shell_guard_rejects_cross_arch_before_preparation(self):
        source = (REPO / "scripts/package_desktop_local.sh").read_text()
        guard = source[source.index('if [ "${PLATFORM}" != "${HOST_OS}" ]; then'):source.index('# ───────── 必备工具检查')]
        self.assertLess(source.index(guard), source.index("install_linux_deps()"))
        self.assertLess(source.index(guard), source.index("=== prepare_flavor"))
        for platform in ("linux", "macos"):
            for host in ("amd64", "arm64"):
                for target in ("amd64", "arm64"):
                    with self.subTest(platform=platform, host=host, target=target):
                        env = dict(os.environ, PLATFORM=platform, HOST_OS=platform, HOST_ARCH=host, ARCH=target, TARGET=f"{platform}-{target}")
                        process = subprocess.run(["bash", "-c", guard], env=env, capture_output=True)
                        self.assertEqual(process.returncode, 0 if host == target else 1)


def elf_header(machine=62, *, endian="<", elf_class=2):
    """ELF64 header without native compilation; suitable for architecture checks."""
    ident = b"\x7fELF" + bytes((elf_class, 1 if endian == "<" else 2, 1, 0)) + bytes(8)
    return struct.pack(endian + "16sHHIQQQIHHHHHH", ident, 3, machine, 1, 0, 0, 0, 0, 64, 56, 0, 64, 0, 0)


FAKE_TOOL = r'''#!{python}
import base64, json, os, pathlib, struct, subprocess, sys
request = json.loads(pathlib.Path(os.environ['XFL_FAKE_REQUEST']).read_text())
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open('commands.jsonl', 'a') as log:
    log.write(json.dumps([tool, args]) + '\n')
if tool == 'uname':
    print(request.get('machine', 'x86_64'))
    sys.exit(request.get('uname_exit', 0))
if tool == 'ldd':
    if request.get('ldd_exit'):
        print('real ldd failure', file=sys.stderr)
        sys.exit(9)
    name = pathlib.Path(args[-1]).name
    for source in request.get('dependencies', {{}}).get(name, []):
        print(' libdependency.so => ' + source + ' (0x123)')
elif tool == 'locate':
    if request.get('locate_exit'):
        print('real locate failure', file=sys.stderr)
        sys.exit(7)
    print(request.get('locations', {{}}).get(args[0], ''))
elif tool == 'cp':
    if args[0] != '-r' and request.get('cp_exit'):
        print('real cp failure', file=sys.stderr)
        sys.exit(6)
    sys.exit(subprocess.run([{cp}, *args]).returncode)
elif tool == 'appimagetool':
    # AppImageKit 5735cc5 accepts this exact internal spelling, not aarch64.
    arch = os.environ.get('ARCH')
    if arch not in ('x86_64', 'arm_aarch64'):
        print('Unsupported ARCH for AppImageKit 5735cc5: ' + str(arch), file=sys.stderr)
        sys.exit(11)
    expected = 62 if arch == 'x86_64' else 183
    machines = set()
    for entry in pathlib.Path(args[0]).rglob('*'):
        if entry.is_file():
            data = entry.read_bytes()
            if data[:4] == b'\x7fELF' and len(data) >= 64:
                machines.add(struct.unpack_from('<H', data, 18)[0])
    if machines != {{expected}}:
        print('ELF payload differs from requested ARCH', file=sys.stderr)
        sys.exit(12)
    if request.get('appimagetool_exit'):
        print('real appimagetool failure', file=sys.stderr)
        sys.exit(8)
    libraries = pathlib.Path(args[0]) / 'usr/lib'
    pathlib.Path(args[1]).write_text(json.dumps({{
        'ARCH': os.environ.get('ARCH'),
        'modes': {{str(p.relative_to(args[0])): p.stat().st_mode & 0o777 for p in pathlib.Path(args[0]).rglob('*') if not p.is_symlink()}},
        'executor_parent': os.readlink('/proc/' + str(os.getppid()) + '/exe'),
        'executor_parent_comm': pathlib.Path('/proc/' + str(os.getppid()) + '/comm').read_text().strip(),
        'executor_parent_argv': pathlib.Path('/proc/' + str(os.getppid()) + '/cmdline').read_bytes().decode().strip('\0').split('\0'),
        'libraries': {{p.name: base64.b64encode(p.read_bytes()).decode() for p in libraries.iterdir()}},
    }}))
elif tool == 'flutter':
    print('Fake flutter: no client or native compilation')
'''


class LinuxAppImageMakerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="xfl-packager-dart-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.tools = cls.root / "tools"
        try:
            cls.dart = shutil.which("dart")
            if not cls.dart or sys.platform != "linux":
                raise RuntimeError("The real maker regression requires Linux and Dart")
            # Flutter's bin/dart wrapper calls uname before running Dart. Bypass
            # that wrapper so fake uname only reaches the code under test.
            runtime = Path(cls.dart).resolve().parent / "cache/dart-sdk/bin/dart"
            if runtime.is_file():
                cls.dart = str(runtime)
            PACKAGER.prepare(SOURCE, cls.tools)
            cls.config = package_configuration(cls.root / "package_config.json", PACKAGER.OUTPUT)
            # Test the isolated fresh copy rather than an already activated tree.
            data = json.loads(cls.config.read_text())
            for entry in data["packages"]:
                if entry["name"] in ("flutter_app_builder", "flutter_app_packager", "shell_executor"):
                    entry["rootUri"] = (cls.tools / "packages" / entry["name"]).as_uri()
            cls.config.write_text(json.dumps(data))
            source = (cls.tools / "packages/flutter_distributor/lib/src/flutter_distributor.dart").read_text()
            method = source[source.index("  Future<List<MakeResult>> package("):source.index("  Future<List<PublishResult>> publish(")]
            cls.fixture = cls.root / "linux_appimage_maker.dart"
            executor = (cls.tools / "packages/flutter_distributor/lib/src/utils/default_shell_executor.dart").read_text()
            executor_class = executor[executor.index("class DefaultShellExecutor extends ShellExecutor {"):]
            # Keep the production constructor registration, not a base executor.
            registration = re.search(r"ShellExecutor\.global = DefaultShellExecutor\(\);", source).group(0)
            cls.fixture.write_text(FIXTURE.read_text()
                .replace("  // INSERT_PRODUCTION_PACKAGE_METHOD", method)
                .replace("// INSERT_PRODUCTION_DEFAULT_SHELL_EXECUTOR", executor_class)
                .replace("// INSERT_PRODUCTION_EXECUTOR_REGISTRATION", registration))
        except RuntimeError as error:
            if os.environ.get("LINUX_PACKAGER_REQUIRE_DART") == "1":
                raise AssertionError(str(error)) from error
            raise unittest.SkipTest(str(error)) from error

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(prefix="case-", dir=self.root)
        self.addCleanup(self.case.cleanup)
        self.work = Path(self.case.name)
        (self.work / "bundle/lib").mkdir(parents=True)
        for name in ("libflutter_linux_gtk.so", "libplugin_a.so", "libplugin_b.so"):
            (self.work / "bundle/lib" / name).write_bytes(elf_header())
        for arch in ("x64", "arm64"):
            bundle = self.work / "build/linux" / arch / "release/bundle"
            bundle.parent.mkdir(parents=True)
            bundle.symlink_to(self.work / "bundle", target_is_directory=True)
        (self.work / "icon.png").write_text("icon fixture")
        (self.work / "pubspec.yaml").write_text("name: fixture\nversion: 1.0.0+1\n")
        (self.work / "linux/packaging/appimage").mkdir(parents=True)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        script = FAKE_TOOL.format(python=sys.executable, cp=repr(shutil.which("cp")))
        for name in ("uname", "ldd", "locate", "cp", "appimagetool", "flutter"):
            executable = self.bin / name
            executable.write_text(script)
            executable.chmod(0o755)

    def library(self, name="libshared.so.1", directory="one", content=None):
        target = self.work / directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(elf_header() if content is None else content)
        return str(target)

    def run_maker(self, dependencies=None, include=None, **request):
        (self.work / "commands.jsonl").unlink(missing_ok=True)
        process_umask = request.pop("umask", -1)
        request["dependencies"] = dependencies or {}
        config = {"display_name": "Fixture", "icon": "icon.png", "include": list((include or {}).keys())}
        (self.work / "linux/packaging/appimage/make_config.yaml").write_text(json.dumps(config))
        request["locations"] = include or {}
        request_file = self.work / "request.json"
        request_file.write_text(json.dumps(request))
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], XFL_FAKE_REQUEST=str(request_file))
        process = subprocess.run([self.dart, "--packages=" + str(self.config), str(self.fixture), str(request_file)], cwd=self.work, env=env, umask=process_umask, capture_output=True, text=True, timeout=60)
        results = [line.removeprefix("XFL_RESULT:") for line in process.stdout.splitlines() if line.startswith("XFL_RESULT:")]
        self.assertEqual(len(results), 1, process.stdout + process.stderr)
        self.last_returncode = process.returncode
        self.commands = [json.loads(line) for line in (self.work / "commands.jsonl").read_text().splitlines()] if (self.work / "commands.jsonl").exists() else []
        self.last_result = json.loads(results[0])
        return self.last_result

    def real_ldd_bundle(self):
        """Compile only a tiny public shared object, never the client."""
        source=self.work/'public.c'
        source.write_text('#include <stdio.h>\nvoid fixture(void) { puts("fixture"); }\n')
        library=self.work/'public.so'
        command('cc','-shared','-fPIC',str(source),'-o',str(library))
        header = library.read_bytes()[:20]
        self.assertEqual(header[:6], b'\x7fELF\x02\x01')
        machine = int.from_bytes(header[18:20], 'little')
        self.assertIn(machine, (62, 183))
        self.real_machine = 'x86_64' if machine == 62 else 'aarch64'
        self.real_appimage_arch = 'x86_64' if machine == 62 else 'arm_aarch64'
        for file in (self.work/'bundle/lib').iterdir():
            if file.is_file():shutil.copyfile(library,file)
        # Exercise the system ldd instead of the permissive fake used elsewhere.
        (self.bin/'ldd').unlink()
        for folder in ('cmake/Sentry','pkgconfig'):
            target=self.work/'bundle/lib'/folder;target.mkdir(parents=True)
            (target/'metadata.txt').write_text('public build metadata')
        (self.work/'bundle/lib/README').write_text('not an ELF library')
        (self.work/'bundle/lib/libsentry.a').write_bytes(b'!<arch>\n')
        (self.work/'bundle/lib/libalias.so.1').symlink_to('libplugin_a.so')

    def test_real_ldd_metadata_both_brand_names_and_old_scan_negative(self):
        self.real_ldd_bundle()
        for brand in ('omofly','daishu'):
            with self.subTest(brand=brand):
                shutil.rmtree(self.work/'dist',ignore_errors=True)
                (self.work/'distribute_options.yaml').write_text('app_name: '+brand+'\n')
                result=self.run_maker(machine=self.real_machine)
                self.assertTrue(result['ok'],result)
                self.assertEqual(self.artifact()['ARCH'],self.real_appimage_arch)
        wrong_machine = 'aarch64' if self.real_machine == 'x86_64' else 'x86_64'
        mismatch = self.run_maker(machine=wrong_machine)
        self.assertFalse(mismatch['ok'], mismatch)
        self.assertIn('ELF architecture mismatch', mismatch['error'])
        maker=self.tools/'packages/flutter_app_packager/lib/src/makers/appimage/app_package_maker_appimage.dart'
        original=maker.read_text()
        guard='          if (!await _isDependencyInput(so)) return <String>{};\n'
        self.assertIn(guard,original)
        try:
            maker.write_text(original.replace(guard,''))
            result=self.run_maker(machine=self.real_machine)
            self.assertFalse(result['ok'],result)
            self.assertRegex(result['error'],r'not regular file|not a dynamic executable')
            self.assertFalse([entry for entry in self.commands if entry[0]=='appimagetool'])
        finally:maker.write_text(original)

    def test_real_ldd_missing_library_is_not_hidden_by_metadata_filter(self):
        self.real_ldd_bundle()
        dep=self.work/'dependency';dep.mkdir()
        (dep/'dep.c').write_text('void required_fixture(void) {}\n')
        command('cc','-shared','-fPIC',str(dep/'dep.c'),'-o',str(dep/'librequired_fixture.so'))
        (dep/'plugin.c').write_text('extern void required_fixture(void); void fixture(void) { required_fixture(); }\n')
        command('cc','-shared','-fPIC',str(dep/'plugin.c'),'-L'+str(dep),
                '-lrequired_fixture','-Wl,-rpath,'+str(dep),'-o',str(self.work/'bundle/lib/libplugin_a.so'))
        (dep/'librequired_fixture.so').unlink()
        result=self.run_maker(machine=self.real_machine)
        self.assertFalse(result['ok'],result)
        self.assertIn('Missing shared dependency',result['error'])
        self.assertFalse([entry for entry in self.commands if entry[0]=='appimagetool'])

    def test_restrictive_umask_keeps_packaged_dirs_traversable(self):
        (self.work / 'bundle/data').mkdir()
        asset=self.work/'bundle/data/file';asset.write_text('public fixture');asset.chmod(0o600)
        (self.work/'bundle/data').chmod(0o700)
        result=self.run_maker(umask=0o077)
        self.assertTrue(result['ok'],result)
        modes=self.artifact()['modes']
        self.assertEqual(modes['data'],0o755)
        self.assertEqual(modes['data/file'],0o644)
        self.assertEqual(modes['AppRun'],0o755)
        self.assertEqual(asset.stat().st_mode & 0o777,0o600)

    def dependency_copies(self):
        return [args for tool, args in self.commands if tool == "cp" and args[0] != "-r"]

    def artifact(self):
        files = list((self.work / "dist").glob("*.AppImage"))
        self.assertEqual(len(files), 1)
        return json.loads(files[0].read_text())

    def test_shared_dependency_and_include_are_copied_once(self):
        lib = self.library()
        result = self.run_maker({"libplugin_a.so": [lib], "libplugin_b.so": [lib]}, {"shared": lib})
        self.assertTrue(result["ok"], result)
        self.assertEqual(len(self.dependency_copies()), 1)
        self.assertEqual(set(self.artifact()["libraries"]), {"libshared.so.1"})

    def test_realpath_alias_preserves_requested_soname(self):
        actual = self.library(name="libshared.so.1.2.3")
        aliases = []
        for directory in ("alias_a", "alias_b"):
            alias = self.work / directory / "libshared.so.1"
            alias.parent.mkdir()
            alias.symlink_to(actual)
            aliases.append(str(alias))
        result = self.run_maker({"libplugin_a.so": [aliases[0]], "libplugin_b.so": [aliases[1]]}, {"shared": aliases[1]})
        self.assertTrue(result["ok"], result)
        self.assertEqual(len(self.dependency_copies()), 1)
        self.assertEqual(set(self.artifact()["libraries"]), {"libshared.so.1"})

    def test_same_basename_and_contents_are_copied_once(self):
        # Exercise both chunk boundaries and a final short read.
        first = self.library(directory="a", content=b"x" * (64 * 1024 + 17))
        second = self.library(directory="b", content=b"x" * (64 * 1024 + 17))
        result = self.run_maker({"libplugin_a.so": [first]}, {"shared": second})
        self.assertTrue(result["ok"], result)
        self.assertEqual(len(self.dependency_copies()), 1)

    def test_conflicting_contents_fail_before_any_dependency_copy(self):
        for different in (b"short", b"x" * (64 * 1024) + b"Y"):
            with self.subTest(size=len(different)):
                first = self.library(directory="a", content=b"x" * (64 * 1024 + 1))
                second = self.library(directory="b", content=different)
                unique = self.library("liba_unique.so")
                result = self.run_maker({"libplugin_a.so": [first, unique]}, {"shared": second})
                self.assertFalse(result["ok"])
                self.assertIn("Conflicting AppImage dependency libshared.so.1", result["error"])
                self.assertEqual(self.dependency_copies(), [])

    def test_missing_dependency_and_ldd_not_found_remain_errors(self):
        for missing in (str(self.work / "missing.so"), "not found"):
            with self.subTest(missing=missing):
                result = self.run_maker({"libplugin_a.so": [missing]})
                self.assertFalse(result["ok"], result)
                self.assertEqual(self.dependency_copies(), [])

    def test_ldd_copy_locate_and_appimagetool_failures_propagate(self):
        lib = self.library()
        for failure, message in (("ldd_exit", "real ldd failure"), ("cp_exit", "real cp failure"), ("locate_exit", "real locate failure"), ("appimagetool_exit", "real appimagetool failure")):
            with self.subTest(failure=failure):
                result = self.run_maker({"libplugin_a.so": [lib]}, {"shared": lib}, **{failure: 1})
                self.assertFalse(result["ok"])
                self.assertIn(message, result["error"])
                self.assertEqual(result["error_type"], "MakeError")

    def test_empty_include_lookup_remains_an_error(self):
        result = self.run_maker(include={"missing": ""})
        self.assertFalse(result["ok"])
        self.assertIn("Can't find specified shared object missing", result["error"])

    def test_real_cp_failure_is_not_suppressed(self):
        source = self.work / "libdirectory.so"
        source.mkdir()
        result = self.run_maker({"libplugin_a.so": [str(source)]})
        self.assertFalse(result["ok"], result)
        self.assertIn("libdirectory.so", result["error"])
        self.assertEqual(result["error_type"], "MakeError")
        self.assertFalse([entry for entry in self.commands if entry[0] == "appimagetool"])

    def test_flutter_baseline_dependency_filter_is_preserved(self):
        baseline = self.library("libbaseline.so")
        own = self.library("libown.so")
        result = self.run_maker({"libflutter_linux_gtk.so": [baseline], "libplugin_a.so": [baseline, own]})
        self.assertTrue(result["ok"], result)
        self.assertEqual(set(self.artifact()["libraries"]), {"libown.so"})

    def test_architecture_reaches_loader_and_appimagetool(self):
        for machine, arch, appimage in (("x86_64", "x64", "x86_64"), ("amd64", "x64", "x86_64"), ("aarch64", "arm64", "arm_aarch64"), ("arm64", "arm64", "arm_aarch64")):
            with self.subTest(machine=machine):
                for file in (self.work / "bundle/lib").iterdir():
                    file.write_bytes(elf_header(62 if arch == "x64" else 183))
                result = self.run_maker(machine=machine, distributor=True)
                self.assertTrue(result["ok"], result)
                self.assertEqual(self.last_returncode, 0)
                self.assertEqual(result["arch"], arch)
                self.assertEqual(self.artifact()["ARCH"], appimage)

    def assert_elf_error(self, message, **request):
        result = self.run_maker(**request)
        self.assertFalse(result["ok"], result)
        self.assertIn(message, result["error"])
        self.assertEqual(result["error_type"], "MakeError")
        self.assertFalse([entry for entry in self.commands if entry[0] == "appimagetool"])
        audit_path = self.work / "build/appimage-elf-audit.json"
        audit = json.loads(audit_path.read_text())
        self.assertEqual(audit["status"], "failed")
        self.assertTrue(audit["failure_code"])
        self.assertNotIn(str(self.work), audit_path.read_text())
        self.assertTrue(all(not Path(entry["path"]).is_absolute() for entry in audit["elf_files"]))

    def test_old_tool_double_rejects_aarch64_spelling(self):
        request = self.work / "direct-request.json"
        request.write_text("{}")
        result = subprocess.run(
            [str(self.bin / "appimagetool"), str(self.work / "bundle"), str(self.work / "direct.AppImage")],
            cwd=self.work, env=dict(os.environ, XFL_FAKE_REQUEST=str(request), ARCH="aarch64"),
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 11)
        self.assertIn("Unsupported ARCH for AppImageKit 5735cc5: aarch64", result.stderr)
        self.assertFalse((self.work / "direct.AppImage").exists())

    def test_full_production_default_executor_passes_arch_through_shell(self):
        result = self.run_maker(distributor=True)
        self.assertTrue(result["ok"], result)
        artifact = self.artifact()
        self.assertEqual(artifact["ARCH"], "x86_64")
        audit_path = self.work / "build/appimage-elf-audit.json"
        audit = json.loads(audit_path.read_text())
        self.assertEqual(audit["status"], "passed")
        self.assertEqual(audit["failure_code"], "")
        self.assertEqual(audit["expected_arch"], "x64")
        self.assertEqual(audit["expected_machine"], 62)
        self.assertEqual(len(audit["elf_files"]), 3)
        self.assertTrue(all(entry["class"] == 2 and entry["endianness"] == 1 and entry["machine"] == 62 for entry in audit["elf_files"]))
        self.assertNotIn(str(self.work), audit_path.read_text())
        self.assertTrue(is_shell_parent(artifact['executor_parent'],
                        artifact['executor_parent_comm'], artifact['executor_parent_argv']), artifact)
        executor = (self.tools / "packages/flutter_distributor/lib/src/utils/default_shell_executor.dart").read_text()
        production_class = executor[executor.index("class DefaultShellExecutor extends ShellExecutor {"):]
        self.assertIn(production_class, self.fixture.read_text())
        self.assertIn("ShellExecutor.global = DefaultShellExecutor();", self.fixture.read_text())

    def test_mixed_bundle_and_copied_dependency_are_rejected(self):
        for machine, expected, foreign in (("x86_64", 62, 183), ("aarch64", 183, 62)):
            for location in ("bundle", "dependency", "include"):
                with self.subTest(machine=machine, location=location):
                    for file in (self.work / "bundle/lib").iterdir():
                        file.write_bytes(elf_header(expected))
                    mixed = self.library(content=elf_header(foreign))
                    kwargs = {}
                    if location == "bundle":
                        (self.work / "bundle/lib/libplugin_a.so").write_bytes(elf_header(foreign))
                    elif location == "dependency":
                        kwargs["dependencies"] = {"libplugin_a.so": [mixed]}
                    else:
                        kwargs["include"] = {"foreign": mixed}
                    self.assert_elf_error("ELF architecture mismatch", machine=machine, distributor=True, **kwargs)
                    self.assertEqual(self.last_returncode, 1)
                    if location != "bundle":
                        self.assertEqual(len(self.dependency_copies()), 1)

    def test_non_elf_offset_18_traps_are_ignored(self):
        # AppImageKit's old sniffing logic reads e_machine's offset in every
        # file. Actual validation must first require the ELF magic.
        for prefix, machine in ((b"#!/bin/sh\n", 183), (b"MZ", 62), (b"PNG", 40)):
            data = bytearray(prefix.ljust(64, b"x"))
            struct.pack_into("<H", data, 18, machine)
            (self.work / "bundle" / ("trap-" + str(machine))).write_bytes(data)
        for machine, elf_machine in (("x86_64", 62), ("aarch64", 183)):
            with self.subTest(machine=machine):
                for file in (self.work / "bundle/lib").iterdir():
                    file.write_bytes(elf_header(elf_machine))
                result = self.run_maker(machine=machine, distributor=True)
                self.assertTrue(result["ok"], result)

    def test_invalid_elf_headers_fail_with_path(self):
        broken = self.work / "bundle/lib/libplugin_a.so"
        cases = [
            (b"\x7fELF", "Truncated ELF header"),
            (elf_header(elf_class=1), "Unsupported ELF class 1"),
            (elf_header(endian=">"), "Unsupported ELF endianness 2"),
            (elf_header(243), "Unsupported ELF e_machine 243"),
        ]
        for offset in (6, 20, 52):
            data = bytearray(elf_header())
            data[offset] = 0
            cases.append((bytes(data), "Invalid ELF version or header size"))
        for data, message in cases:
            with self.subTest(message=message, header=data.hex()):
                broken.write_bytes(data)
                self.assert_elf_error(message)
                self.assertIn("libplugin_a.so", self.last_result["error"])

    def test_appdir_without_valid_target_elf_is_rejected(self):
        for file in (self.work / "bundle/lib").iterdir():
            file.write_text("ordinary data, not ELF")
        self.assert_elf_error("contains no valid ELF64 for x64")

    def test_internal_symlinks_and_directory_cycle_are_checked_once(self):
        (self.work / "bundle/plugin-link").symlink_to("lib/libplugin_a.so")
        (self.work / "bundle/lib/root-link").symlink_to("..", target_is_directory=True)
        result = self.run_maker()
        self.assertTrue(result["ok"], result)

    def test_foreign_elf_reached_via_internal_symlink_is_rejected(self):
        (self.work / "bundle/foreign.bin").write_bytes(elf_header(183))
        (self.work / "bundle/first-link").symlink_to("foreign.bin")
        self.assert_elf_error("ELF architecture mismatch")

    def test_dangling_and_external_appdir_links_are_rejected(self):
        link = self.work / "bundle/link"
        link.symlink_to("missing")
        self.assert_elf_error("Invalid AppImage link or file")
        link.unlink()
        link.symlink_to(self.library())
        self.assert_elf_error("AppImage link escapes AppDir")

    def test_unknown_make_architecture_is_rejected_before_copy(self):
        for arch in (None, "riscv64", "x86_64"):
            with self.subTest(arch=arch):
                result = self.run_maker(config_arch=arch)
                self.assertFalse(result["ok"])
                self.assertIn("Unsupported AppImage architecture", result["error"])
                self.assertEqual(self.dependency_copies(), [])
                self.assertFalse([entry for entry in self.commands if entry[0] == "cp"])

    def test_unknown_machine_and_uname_failure_propagate(self):
        for arguments, message in (({"machine": "riscv64"}, "Unsupported Linux architecture"), ({"uname_exit": 8}, "Unable to determine Linux architecture")):
            with self.subTest(arguments=arguments):
                result = self.run_maker(distributor=True, **arguments)
                self.assertFalse(result["ok"])
                self.assertIn(message, result["error"])
                self.assertEqual(result["error_type"], "StateError")
                self.assertEqual(self.last_returncode, 1)
                self.assertFalse((self.work / "maker-called").exists())
                self.assertEqual(list((self.work / "dist").iterdir()), [])
                self.assertFalse([entry for entry in self.commands if entry[0] == "appimagetool"])

    def test_production_distributor_injects_linux_build_result_arch(self):
        source = (self.tools / "packages/flutter_distributor/lib/src/flutter_distributor.dart").read_text()
        self.assertIn("if (buildResult is BuildLinuxResult) 'arch': buildResult.arch,", source)
        self.assertIn("'arch': (buildResult as BuildWindowsResult).arch,", source)


if __name__ == "__main__":
    unittest.main()
