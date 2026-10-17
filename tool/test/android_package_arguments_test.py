#!/usr/bin/env python3
"""Run the pinned distributor parser and builder against a fake Flutter process.

No client compilation, pub resolution, global activation, or network is involved.
Only package makers, publishers and terminal/Windows decoding helpers are replaced. CommandPackage,
FlutterDistributor and FlutterAppBuilder execute directly from the submodule.
Run after `flutter pub get`, with Dart on PATH.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import urljoin

try:
    from .sentry_release_workflow_test import step_script
except ImportError:
    from sentry_release_workflow_test import step_script


ROOT = Path(__file__).resolve().parents[2]
VENDORED = ROOT / "plugins/flutter_distributor/packages"


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX shell fixture required")
class AndroidPackageArgumentsTests(unittest.TestCase):
    def setUp(self):
        self.dart = shutil.which("dart")
        if not self.dart:
            self.fail("Dart is required; run with the Flutter toolchain on PATH")
        # Flutter's bin/dart shell wrapper overwrites FLUTTER_ROOT. Invoke the
        # bundled VM directly so the builder can only find our fake Flutter.
        bundled_dart = Path(self.dart).resolve().parent / "cache/dart-sdk/bin/dart"
        if bundled_dart.is_file():
            self.dart = str(bundled_dart)
        config_path = ROOT / ".dart_tool/package_config.json"
        if not config_path.exists():
            self.fail("Run flutter pub get before the distributor argv regression")
        self.temporary = tempfile.TemporaryDirectory(prefix="android-package-argv-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        config = json.loads(config_path.read_text())
        packages = {item["name"]: {**item, "rootUri": urljoin(config_path.as_uri(), item["rootUri"])}
                    for item in config["packages"]}
        for name in ("flutter_distributor", "flutter_app_builder", "shell_executor", "shell_uikit"):
            packages[name] = {"name": name, "rootUri": (VENDORED / name).as_uri(),
                              "packageUri": "lib/", "languageVersion": "2.16"}
        # Fake makers deliberately never execute appdmg/rpm/Gradle or inspect native files.
        self.fixture_package(packages, "flutter_app_packager", '''
import 'dart:io';
class MakeResult {
  final List<FileSystemEntity> artifacts = [File('dist/fixture.apk')];
  Map<String, dynamic> toJson() => {};
}
class FlutterAppPackager {
  Future<MakeResult> package(String platform, String target,
      Map<String, dynamic>? arguments, Directory outputDirectory,
      {required Directory buildOutputDirectory, required List<File> buildOutputFiles}) async {
    if (platform != 'android' || target != 'apk') throw StateError('Unexpected fixture target');
    return MakeResult();
  }
}
''')
        self.fixture_package(packages, "flutter_app_publisher", '''
import 'dart:io';
class PublishResult { String get url => throw StateError('No publishing in argv regression'); }
class FlutterAppPublisher {
  Future<PublishResult> publish(FileSystemEntity file, {String? target,
      Map<String, String>? environment, Map<String, dynamic>? publishArguments,
      void Function(int, int)? onPublishProgress}) => throw StateError('No publishing in argv regression');
}
''')
        self.fixture_package(packages, "ansicolor", '''
const ansiEscape = '\\u001b[';
const ansiDefault = '';
class AnsiPen {
  void xterm(int color, {bool bg = false}) {}
  String call(String text) => text;
}
''')
        self.fixture_package(packages, "charset", '''
import 'dart:convert';
class Charset {
  static Encoding? detect(List<int> bytes) => throw StateError('Windows decoding is outside this POSIX fixture');
}
''')
        self.config = self.root / "package_config.json"
        self.config.write_text(json.dumps({"configVersion": 2, "packages": list(packages.values())}))
        self.harness = self.root / "main.dart"
        command_uri = (VENDORED / "flutter_distributor/bin/command_package.dart").as_uri()
        self.harness.write_text("import 'package:args/command_runner.dart';\n"
                                "import 'package:flutter_distributor/flutter_distributor.dart';\n"
                                f"import '{command_uri}';\n"
                                "Future<void> main(List<String> args) async {\n"
                                "  final runner = CommandRunner('fixture', '')\n"
                                "    ..addCommand(CommandPackage(FlutterDistributor()));\n"
                                "  await runner.run(args);\n}\n")
        (self.root / "pubspec.yaml").write_text("name: fixture\nversion: 0.0.0+101\n")
        self.record = self.root / "flutter-argv.json"
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "FLUTTER_ROOT": str(self.root), "RECORDED_ARGS": str(self.record),
                    "FLAVOR": "brand_a", "BASE_VERSION": "0.0.0", "BUILD_NUMBER": "101"}
        flutter = self.bin / "flutter"
        flutter.write_text("#!/usr/bin/env python3\nimport json, os, pathlib, sys\n"
                           "args = sys.argv[1:]\n"
                           "pathlib.Path(os.environ['RECORDED_ARGS']).write_text(json.dumps(args))\n"
                           "if '--android-arm64' in args:\n"
                           "    print('Could not find an option named android-arm64', file=sys.stderr)\n"
                           "    sys.exit(64)\n"
                           "assert args[:2] == ['build', 'apk'], args\n"
                           "pathlib.Path('build/app/outputs/flutter-apk').mkdir(parents=True, exist_ok=True)\n")
        flutter.chmod(0o755)

    def fixture_package(self, packages, name, source):
        directory = self.root / "fixtures" / name
        (directory / "lib").mkdir(parents=True)
        (directory / "lib" / (name + ".dart")).write_text(source)
        packages[name] = {"name": name, "rootUri": directory.as_uri(),
                          "packageUri": "lib/", "languageVersion": "2.16"}

    def run_distributor(self, arguments):
        return subprocess.run([self.dart, "--packages=" + str(self.config), str(self.harness),
                               *arguments], cwd=self.root, env=self.env,
                              text=True, capture_output=True, timeout=60)

    def test_workflow_preserves_the_complete_android_flutter_argv(self):
        # Execute the real workflow Bash block to obtain its exact distributor args.
        dart = self.bin / "dart"
        dart.write_text("#!/usr/bin/env python3\nimport json, os, pathlib, sys\n"
                        "pathlib.Path(os.environ['RECORDED_ARGS']).write_text(json.dumps(sys.argv[1:]))\n")
        dart.chmod(0o755)
        script = step_script("Package (flutter_distributor)").replace("${{ matrix.platform }}", "android").replace(
            "${{ matrix.arch }}", "")
        shell = subprocess.run(["bash", "-c", script], cwd=self.root, env=self.env,
                               text=True, capture_output=True, timeout=10)
        self.assertEqual(shell.returncode, 0, shell.stderr)
        outer_args = json.loads(self.record.read_text())
        self.assertEqual(outer_args[:4], ["pub", "global", "run", "flutter_distributor:main"])
        result = self.run_distributor(outer_args[4:])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        actual = json.loads(self.record.read_text())
        self.assertEqual(actual, [
            "build", "apk", "--target-platform", "android-arm,android-arm64", "--flavor", "brand_a",
            "--dart-define-from-file", "env.json", "--build-name", "0.0.0", "--build-number", "101",
            "--split-debug-info", "build/debug-info", "--split-per-abi",
            "--dart-define", "FLUTTER_BUILD_NAME=0.0.0", "--dart-define", "FLUTTER_BUILD_NUMBER=101",
        ])

    def test_old_comma_delimited_target_platform_reaches_flutter_as_an_invalid_flag(self):
        # Mutation guard: the old workflow must fail through the same real parser/builder.
        result = self.run_distributor([
            "package", "--skip-clean", "--platform", "android", "--targets", "apk",
            "--flutter-build-args=split-per-abi,target-platform=android-arm,android-arm64,flavor=brand_a",
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.record.exists(), result.stdout + result.stderr)
        actual = json.loads(self.record.read_text())
        self.assertIn("--android-arm64", actual)
        self.assertEqual(actual[actual.index("--target-platform") + 1], "android-arm")
        self.assertIn("Could not find an option named android-arm64", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
