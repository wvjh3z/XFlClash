#!/usr/bin/env python3
"""Execute release workflow shell blocks with stubs; never build the client."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
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


if __name__ == "__main__":
    unittest.main()
