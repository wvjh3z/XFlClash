"""Offline regression of the pinned patch and the actual Dart AppImage maker.

Fake ldd/locate/appimagetool operate on ordinary files; cp is the real system cp.
No pub get, Flutter compilation, native build, or network operations are run.
CI sets LINUX_PACKAGER_REQUIRE_DART=1 to make missing prerequisites a failure.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import unquote, urljoin, urlparse


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("prepare_linux_packager", REPO / "tool/prepare_linux_packager.py")
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)
SOURCE = REPO / "plugins/flutter_distributor"
FIXTURE = REPO / "tool/test/fixtures/linux_appimage_maker.dart"


def command(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=60, **kwargs)


def package_configuration(output: Path, tools: Path) -> Path:
    """Reuse resolved configs/cache, with absolute URIs; never resolve packages."""
    cache = Path(os.environ.get("PUB_CACHE", str(Path.home() / ".pub-cache")))
    configs = [
        REPO / ".dart_tool/package_config.json",
        tools / "packages/flutter_distributor/.dart_tool/package_config.json",
        cache / "global_packages/flutter_distributor/.dart_tool/package_config.json",
    ]
    if os.environ.get("LINUX_PACKAGER_PACKAGE_CONFIG"):
        configs.append(Path(os.environ["LINUX_PACKAGER_PACKAGE_CONFIG"]))
    packages = {}
    hosted = {cache / "hosted/pub.dev"}
    for config in configs:
        if not config.is_file():
            continue
        for entry in json.loads(config.read_text())["packages"]:
            entry = dict(entry)
            entry["rootUri"] = urljoin(config.as_uri(), entry["rootUri"])
            packages[entry["name"]] = entry
            local = Path(unquote(urlparse(entry["rootUri"]).path))
            if local.parent.name == "pub.dev":
                hosted.add(local.parent)
    if not packages:
        raise RuntimeError("No resolved Dart package_config found; prepare dependencies first")
    # The application doesn't depend on mustache_template, but the real maker
    # does. Global activation resolves it in CI; local runs can reuse its cache.
    if "mustache_template" not in packages:
        candidates = sorted(p for root in hosted for p in root.glob("mustache_template-2.*"))
        if not candidates:
            raise RuntimeError("mustache_template is absent from resolved configs and local cache")
        packages["mustache_template"] = {
            "name": "mustache_template", "rootUri": candidates[-1].as_uri(),
            "packageUri": "lib/", "languageVersion": re.search(
                r"sdk:\s*['\"]?[\^>= ]*(\d+\.\d+)",
                (candidates[-1] / "pubspec.yaml").read_text(),
            ).group(1),
        }
    for name in ("flutter_app_builder", "flutter_app_packager", "shell_executor"):
        packages[name] = {
            "name": name, "rootUri": (tools / "packages" / name).as_uri(),
            "packageUri": "lib/", "languageVersion": "2.16",
        }
    for name in ("path", "pub_semver", "pubspec_parse", "yaml", "collection", "meta", "mustache_template"):
        entry = packages.get(name)
        if not entry or not Path(unquote(urlparse(entry["rootUri"]).path)).is_dir():
            raise RuntimeError(f"Required cached Dart dependency unavailable: {name}")
    output.write_text(json.dumps({"configVersion": 2, "packages": list(packages.values())}))
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
        clone = self.root / "source"
        command("git", "clone", "--quiet", "--shared", "--no-hardlinks", str(SOURCE), str(clone))
        command("git", "-C", str(clone), "checkout", "--quiet", "HEAD^1")
        with self.assertRaisesRegex(RuntimeError, "Unexpected distributor revision"):
            PACKAGER.prepare(clone, self.output)

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


FAKE_TOOL = r'''#!{python}
import base64, json, os, pathlib, subprocess, sys
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
    if request.get('appimagetool_exit'):
        print('real appimagetool failure', file=sys.stderr)
        sys.exit(8)
    libraries = pathlib.Path(args[0]) / 'usr/lib'
    pathlib.Path(args[1]).write_text(json.dumps({{
        'ARCH': os.environ.get('ARCH'),
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
            cls.fixture.write_text(FIXTURE.read_text().replace("  // INSERT_PRODUCTION_PACKAGE_METHOD", method))
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
            (self.work / "bundle/lib" / name).write_text("ordinary fixture")
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

    def library(self, name="libshared.so.1", directory="one", content=b"shared contents"):
        target = self.work / directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        return str(target)

    def run_maker(self, dependencies=None, include=None, **request):
        request["dependencies"] = dependencies or {}
        config = {"display_name": "Fixture", "icon": "icon.png", "include": list((include or {}).keys())}
        (self.work / "linux/packaging/appimage/make_config.yaml").write_text(json.dumps(config))
        request["locations"] = include or {}
        request_file = self.work / "request.json"
        request_file.write_text(json.dumps(request))
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], XFL_FAKE_REQUEST=str(request_file))
        process = subprocess.run([self.dart, "--packages=" + str(self.config), str(self.fixture), str(request_file)], cwd=self.work, env=env, capture_output=True, text=True, timeout=60)
        results = [line.removeprefix("XFL_RESULT:") for line in process.stdout.splitlines() if line.startswith("XFL_RESULT:")]
        self.assertEqual(len(results), 1, process.stdout + process.stderr)
        self.last_returncode = process.returncode
        self.commands = [json.loads(line) for line in (self.work / "commands.jsonl").read_text().splitlines()] if (self.work / "commands.jsonl").exists() else []
        return json.loads(results[0])

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
        for machine, arch, appimage in (("x86_64", "x64", "x86_64"), ("amd64", "x64", "x86_64"), ("aarch64", "arm64", "aarch64"), ("arm64", "arm64", "aarch64")):
            with self.subTest(machine=machine):
                result = self.run_maker(machine=machine, distributor=True)
                self.assertTrue(result["ok"], result)
                self.assertEqual(self.last_returncode, 0)
                self.assertEqual(result["arch"], arch)
                self.assertEqual(self.artifact()["ARCH"], appimage)

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
