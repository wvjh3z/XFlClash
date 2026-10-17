#!/usr/bin/env python3
"""Execute release workflow shell blocks with stubs; never build the client."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/release-package.yml"


def step_script(name):
    return script_after_marker("      - name: " + name)


def script_after_marker(marker):
    lines = WORKFLOW.read_text().splitlines()
    begin = lines.index(marker) + 1
    end = next((index for index in range(begin, len(lines))
                if lines[index].startswith("      - ")), len(lines))
    for index in range(begin, end):
        match = re.fullmatch(r"(\s*)run: \|", lines[index])
        if match:
            width = len(match.group(1)) + 2
            body = []
            for line in lines[index + 1:end]:
                if line.strip() and len(line) - len(line.lstrip()) < width:
                    break
                body.append(line[width:] if line.strip() else "")
            return "\n".join(body)
    raise AssertionError("Missing executable workflow step: " + marker)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX shell fixture required")
class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {"PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "FLAVOR": "brand_a", "BASE_VERSION": "0.0.0", "BUILD_NUMBER": "101",
                    "PRODUCT_VERSION": "0.0.1", "GITHUB_SHA": "a" * 40,
                    "BUILD_SOURCE_SHA": "b" * 40,
                    "RECORDED_ARGS": str(self.root / "arguments.json")}

    def stub(self, name):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                        "with open(os.environ['RECORDED_ARGS'],'w') as stream: "
                        "json.dump(sys.argv[1:],stream)\n")
        path.chmod(0o755)

    def execute(self, name, platform, architecture="amd64", token=""):
        script = step_script(name).replace("${{ matrix.platform }}", platform).replace(
            "${{ matrix.arch }}", architecture)
        return subprocess.run(["bash", "-c", script], cwd=self.root, capture_output=True,
                              text=True, env={**self.env, "SENTRY_AUTH_TOKEN": token})

    def stub_python_version(self, version):
        python = self.bin / "python3"
        python.write_text(f"#!{sys.executable}\nimport sys\n"
                          f"sys.version_info = {version!r}\n"
                          f"sys.version = {'.'.join(map(str, version)) + ' (test fixture)'!r}\n"
                          "exec(compile(sys.stdin.read(), '<workflow-python-check>', 'exec'))\n")
        python.chmod(0o755)

    def test_all_release_platforms_require_a_token_without_printing_it(self):
        for platform in ("windows", "android", "linux", "macos"):
            with self.subTest(platform=platform):
                missing = self.execute("Check required Sentry upload credentials", platform)
                self.assertNotEqual(missing.returncode, 0)
                token = "fixture-upload-credential-never-real"
                present = self.execute("Check required Sentry upload credentials", platform, token=token)
                self.assertEqual(present.returncode, 0)
                self.assertNotIn(token, present.stdout + present.stderr)

    def test_combined_desktop_matrix_excludes_locally_validated_targets(self):
        script = script_after_marker("      - id: r")
        output = self.root / "matrix-output"
        expected = {("windows", "amd64"), ("linux", "arm64"),
                    ("macos", "amd64"), ("macos", "arm64")}
        for target, wanted in (("desktop-except-linux-amd64", expected),
                               ("desktop", expected | {("linux", "amd64")}),
                               ("all", expected | {("linux", "amd64"), ("android", "")})):
            with self.subTest(target=target):
                output.unlink(missing_ok=True)
                result = subprocess.run(["bash", "-c", script], cwd=self.root,
                                        capture_output=True, text=True,
                                        env={**self.env, "TARGET": target, "GITHUB_OUTPUT": str(output)})
                self.assertEqual(result.returncode, 0, result.stderr)
                matrix = json.loads(output.read_text().removeprefix("include=").strip())
                self.assertEqual({(item["platform"], item.get("arch", "")) for item in matrix}, wanted)
                self.assertEqual(len(matrix), len(wanted))
                linux_x64 = [item for item in matrix if item["platform"] == "linux" and item.get("arch") == "amd64"]
                if linux_x64:
                    self.assertEqual(linux_x64[0]["os"], "ubuntu-22.04")

        output.unlink(missing_ok=True)
        invalid = subprocess.run(["bash", "-c", script], cwd=self.root, capture_output=True, text=True,
                                 env={**self.env, "TARGET": "unsupported", "GITHUB_OUTPUT": str(output)})
        self.assertNotEqual(invalid.returncode, 0)
        self.assertFalse(output.exists())

    def test_every_packaging_target_receives_dart_split_debug_information(self):
        self.stub("dart")
        for platform, architecture in (("windows", "amd64"), ("android", ""),
                                       ("linux", "amd64"), ("linux", "arm64"),
                                       ("macos", "amd64"), ("macos", "arm64")):
            with self.subTest(platform=platform, architecture=architecture):
                result = self.execute("Package (flutter_distributor)", platform, architecture)
                self.assertEqual(result.returncode, 0, result.stderr)
                arguments = json.loads((self.root / "arguments.json").read_text())
                build_arguments = next(arg for arg in arguments if arg.startswith("--flutter-build-args="))
                self.assertEqual(build_arguments.count("split-debug-info=build/debug-info"), 1)
                self.assertIn("--platform", arguments)
                self.assertEqual(arguments[arguments.index("--platform") + 1], platform)
                self.assertNotIn("fixture-upload-credential-never-real", " ".join(arguments))
                if platform == "android":
                    self.assertIn("--build-target-platform=android-arm,android-arm64", arguments)
                    self.assertEqual(arguments[arguments.index("--build-flavor") + 1], "brand_a")
                    self.assertIn("split-per-abi", build_arguments.split(","))
                    self.assertNotIn("target-platform=", build_arguments)
                    self.assertNotIn("--description", arguments)
                else:
                    self.assertEqual(arguments[arguments.index("--description") + 1], architecture)
                    self.assertFalse(any(arg.startswith("--build-target-platform") for arg in arguments))

    def test_linux_activation_uses_the_prepared_copy_and_other_platforms_keep_the_submodule(self):
        for name in ("python3", "dart"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\nimport json,os,sys\n"
                            "with open(os.environ['RECORDED_ARGS'],'a') as stream: "
                            f"stream.write(json.dumps([{name!r}, *sys.argv[1:]])+'\\n')\n")
            path.chmod(0o755)
        self.env.update(HOME=str(self.root / "home"), LOCALAPPDATA=str(self.root / "local"),
                        GITHUB_PATH=str(self.root / "github-path"))
        output = self.root / "arguments.json"
        for platform in ("android", "linux", "macos", "windows"):
            with self.subTest(platform=platform):
                output.unlink(missing_ok=True)
                result = self.execute("Activate flutter_distributor", platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in output.read_text().splitlines()]
                if platform == "linux":
                    self.assertEqual(calls[0], ["python3", "tool/prepare_linux_packager.py"])
                    expected = "build/packaging-tools/flutter_distributor/packages/flutter_distributor"
                    self.assertEqual(len(calls), 2)
                else:
                    expected = "plugins/flutter_distributor/packages/flutter_distributor"
                    self.assertEqual(len(calls), 1)
                self.assertEqual(calls[-1], ["dart", "pub", "global", "activate", "-s", "path", expected])

    def test_macos_tool_checks_clear_only_managed_diagnostic_slots(self):
        self.stub("npm")
        self.stub("python")
        diagnostics = self.root / "build/sentry-diagnostics/macos"
        diagnostics.mkdir(parents=True)
        for name in ("failure-00.json", "failure-15.json", "unexpected.json", "reader-lifecycle.json",
                     "reader-termination.json", "keep.json", "failure-extra.json", "failure-16.json", "failure-99.json"):
            (diagnostics / name).write_text("fixture")
        self.env["SENTRY_MACOS_DIAGNOSTICS_DIR"] = str(diagnostics)
        result = self.execute("Setup Sentry CLI and verify symbol tooling", "macos")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({path.name for path in diagnostics.iterdir()},
                         {"keep.json", "failure-extra.json", "failure-16.json", "failure-99.json"})
        workflow = WORKFLOW.read_text()
        self.assertLess(workflow.index("name: Setup Python for Linux and macOS tooling"),
                        workflow.index("name: Setup Sentry CLI and verify symbol tooling"))
        self.assertIn("python-version: '3.12'", workflow)
        self.assertIn("SENTRY_MACOS_DIAGNOSTICS_DIR: ${{ matrix.platform == 'macos'", workflow)
        self.assertIn("            build/sentry-diagnostics/macos/", workflow)
        self.assertIn("          if-no-files-found: ignore", workflow)

    def test_linux_and_macos_pin_python_before_packaging_tools(self):
        workflow = WORKFLOW.read_text()
        name = "      - name: Setup Python for Linux and macOS tooling"
        start = workflow.index(name)
        end = workflow.index("      - name:", start + len(name))
        setup = workflow[start:end]
        self.assertIn("if: matrix.platform == 'linux' || matrix.platform == 'macos'", setup)
        self.assertIn("uses: actions/setup-python@v5", setup)
        self.assertIn("python-version: '3.12'", setup)
        # The platform condition covers both Linux CPU targets; no architecture
        # exclusion can leave amd64 on Ubuntu 22.04's default interpreter.
        self.assertNotIn("matrix.arch", setup)
        verify = workflow.index("name: Verify packaging Python")
        verify_end = workflow.index("      - name:", verify)
        self.assertIn("if: matrix.platform == 'linux' || matrix.platform == 'macos'",
                      workflow[verify:verify_end])
        self.assertLess(start, verify)
        for marker in ("name: Setup Sentry CLI and verify symbol tooling",
                       "name: Install Linux package deps",
                       "name: Activate flutter_distributor",
                       "name: Check Linux AppImage packaging without compilation"):
            self.assertLess(verify, workflow.index(marker))

    def test_packaging_python_check_reports_and_accepts_selected_interpreter(self):
        self.stub_python_version((3, 12, 3))
        result = self.execute("Verify packaging Python", "linux")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Packaging Python: 3.12.", result.stdout)

    def test_packaging_python_check_rejects_an_older_interpreter(self):
        self.stub_python_version((3, 10, 12))
        result = self.execute("Verify packaging Python", "linux")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Python 3.12", result.stderr)

    def test_real_packager_checks_run_after_dependency_setup_and_activation(self):
        workflow = WORKFLOW.read_text()
        for marker in ("name: Check Android package argument forwarding",
                       "name: Check Linux AppImage packaging without compilation"):
            self.assertLess(workflow.index("name: Get Flutter dependency"), workflow.index(marker))
            self.assertLess(workflow.index("name: Activate flutter_distributor"), workflow.index(marker))
            self.assertLess(workflow.index(marker), workflow.index("name: Package (flutter_distributor)"))
        self.assertIn("LINUX_PACKAGER_REQUIRE_DART: '1'", workflow)

    def test_windows_checks_real_resource_checkout_before_brand_injection(self):
        workflow = WORKFLOW.read_text()
        marker = "      - name: Check brand resource checkout"
        start = workflow.index(marker)
        end = workflow.index("      - name:", start + len(marker))
        block = workflow[start:end]
        self.assertIn("if: matrix.platform == 'windows'", block)
        self.assertEqual(step_script("Check brand resource checkout").strip(),
                         "flutter test --no-pub tool/test/system_icon_git_checkout_test.dart")
        self.assertLess(workflow.index("name: Get Flutter dependency"), start)
        self.assertLess(start, workflow.index("name: Inject desktop branding"))
        self.assertLess(start, workflow.index("name: Package (flutter_distributor)"))
        self.assertTrue((WORKFLOW.parents[2] / "tool/test/system_icon_git_checkout_test.dart").is_file())

    @unittest.skipUnless(shutil.which("jq"), "The real compose step requires jq")
    def test_compose_uses_resolved_number_instead_of_reading_old_counter(self):
        (self.root / "flavors/brand_a").mkdir(parents=True)
        (self.root / "flavors/brand_a/flavor.yaml").write_text('versionName: "0.0.1"\n')
        (self.root / "flavor_defines.json").write_text(json.dumps({"XB_FLAVOR_ID": "brand_a"}))
        (self.root / "pubspec.yaml").write_text("version: 0.8.93+9999\n")
        (self.root / "scripts").mkdir()
        (self.root / "scripts/build_number.brand_a.txt").write_text("21\n")
        self.env.update(APP_ENV="stable", GITHUB_ENV=str(self.root / "job-env"))
        result = self.execute("Compose env.json", "windows")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / "env.json").read_text())["XB_BUILD_NUMBER"], "101")
        self.assertNotIn("BUILD_NUMBER=", (self.root / "job-env").read_text())
        self.assertEqual((self.root / "scripts/build_number.brand_a.txt").read_text(), "21\n")

    def test_postbuild_receives_final_apks_and_release_metadata_without_bypass(self):
        self.stub("python")
        (self.root / "dist").mkdir()
        for name in ("fixture-arm64-v8a.apk", "fixture-armeabi-v7a.apk"):
            (self.root / "dist" / name).write_bytes(b"fixture")
        for platform, architecture in (("windows", "amd64"), ("android", ""),
                                       ("linux", "amd64"), ("linux", "arm64"),
                                       ("macos", "amd64"), ("macos", "arm64")):
            with self.subTest(platform=platform, architecture=architecture):
                result = self.execute("Prepare, audit and upload matching Sentry symbols",
                                      platform, architecture, token="fixture-credential-only")
                self.assertEqual(result.returncode, 0, result.stderr)
                arguments = json.loads((self.root / "arguments.json").read_text())
                self.assertEqual(arguments[0], "tool/postbuild_sentry_symbols.py")
                self.assertEqual(arguments[arguments.index("--platform") + 1], platform)
                self.assertEqual(arguments[arguments.index("--build-number") + 1], "101")
                self.assertEqual(arguments[arguments.index("--source-revision") + 1], "b" * 40)
                self.assertNotIn("--audit-only", arguments)
                self.assertNotIn("--no-sentry", arguments)
                self.assertNotIn("fixture-credential-only", " ".join(arguments))
                if platform == "android":
                    self.assertEqual(arguments.count("--package"), 2)
                elif platform == "linux":
                    self.assertEqual(arguments[arguments.index("--architecture") + 1],
                                     "x64" if architecture == "amd64" else "arm64")

    def test_android_without_a_final_apk_cannot_reach_the_upload_command(self):
        self.stub("python")
        (self.root / "dist").mkdir()
        result = self.execute("Prepare, audit and upload matching Sentry symbols", "android", "")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "arguments.json").exists())

    def test_mac_probe_selects_the_matrix_slice_before_sending(self):
        path = self.bin / "python"
        path.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                        "with open(os.environ['RECORDED_ARGS'],'a') as stream: "
                        "stream.write(json.dumps(sys.argv[1:])+'\\n')\n")
        path.chmod(0o755)
        output = self.root / "arguments.json"
        for architecture, expected in (("amd64", "x86_64"), ("arm64", "arm64")):
            with self.subTest(architecture=architecture):
                output.unlink(missing_ok=True)
                result = self.execute("Send controlled desktop symbolication probe", "macos", architecture)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in output.read_text().splitlines()]
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[0][0], "tool/pick_sentry_symbolication_probe.py")
                self.assertEqual(calls[0][calls[0].index("--architecture") + 1], expected)
                self.assertEqual(calls[1][:2], ["tool/sentry_desktop_symbolication_probe.py", "emit"])
        output.unlink(missing_ok=True)
        unknown = self.execute("Send controlled desktop symbolication probe", "macos", "unknown")
        self.assertNotEqual(unknown.returncode, 0)
        self.assertFalse(output.exists())

    def test_draft_metadata_tracks_uploaded_build_and_published_releases_are_preserved(self):
        state = self.root / "draft-state.json"
        self.env.update(GITHUB_REPOSITORY="fixture/repo", TAG="pkg-brand_a-v0.0.1",
                        TITLE="brand_a v0.0.1 (build 101)", DRAFT_STATE=str(state))
        (self.root / "dist").mkdir()
        (self.root / "dist/fixture-setup.exe").write_bytes(b"fixture")
        gh = self.bin / "gh"
        gh.write_text("#!/usr/bin/env python3\n" + '''
import json, os, pathlib, sys
path = pathlib.Path(os.environ['DRAFT_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
state['calls'].append(args)
code, output = 0, ''
if args[:2] == ['release', 'view']:
    if not state['exists']:
        code = 1
    elif '--json' in args:
        output = 'true' if state['draft'] else 'false'
elif args[:2] == ['release', 'create']:
    state.update(exists=True, draft='--draft' in args,
                 title=args[args.index('--title') + 1], notes=args[args.index('--notes') + 1])
elif args[:2] == ['release', 'upload']:
    code = 1 if state['uploadFailure'] else 0
    if not code:
        state['uploaded'] = [a for a in args if a.startswith('dist/')]
elif args[:2] == ['release', 'edit']:
    state.update(title=args[args.index('--title') + 1], notes=args[args.index('--notes') + 1])
else:
    code = 2
path.write_text(json.dumps(state))
print(output)
sys.exit(code)
''')
        gh.chmod(0o755)
        for exists, draft, upload_failure in ((False, False, False), (True, True, False),
                                             (True, False, False), (True, True, True)):
            with self.subTest(exists=exists, draft=draft, upload_failure=upload_failure):
                state.write_text(json.dumps({"exists": exists, "draft": draft, "title": "build 9",
                    "notes": "build=9", "uploadFailure": upload_failure, "uploaded": [], "calls": []}))
                result = self.execute("Publish to draft Release", "windows")
                actual = json.loads(state.read_text())
                commands = [call[:2] for call in actual["calls"]]
                if exists and not draft:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn(["release", "upload"], commands)
                    self.assertNotIn(["release", "edit"], commands)
                    self.assertEqual(actual["title"], "build 9")
                elif upload_failure:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn(["release", "edit"], commands)
                    self.assertEqual(actual["title"], "build 9")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(actual["title"], self.env["TITLE"])
                    self.assertIn("build=101", actual["notes"])
                    self.assertEqual(actual["uploaded"], ["dist/fixture-setup.exe"])
                    self.assertLess(commands.index(["release", "upload"]), commands.index(["release", "edit"]))
                    self.assertEqual(commands.count(["release", "create"]), 0 if exists else 1)


if __name__ == "__main__":
    unittest.main()
