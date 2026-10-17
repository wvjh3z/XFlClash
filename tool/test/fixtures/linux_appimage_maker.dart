// Pure Dart driver for the real prepared maker. It never invokes Flutter.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_app_builder/flutter_app_builder.dart';
import 'package:flutter_app_packager/src/api/app_package_maker.dart';
import 'package:flutter_app_packager/src/makers/appimage/app_package_maker_appimage.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

// Only unrelated CLI output and the all-platform maker registry are replaced.
// The test inserts the complete production package method verbatim below; its
// builder, build result, config loader, and AppImage maker remain real.
class _Logger {
  void info(Object message) {}
  void warning(Object message) {}
  void severe(Object message) {}
}

final logger = _Logger();

extension _Colors on String {
  String brightGreen() => this;
  String yellow() => this;
  String red() => this;
}

class _Options {
  Directory get outputDirectory => Directory('dist');
}

class _LinuxPackager {
  Future<MakeResult> package(
    String platform,
    String target,
    Map<String, dynamic>? arguments,
    Directory outputDirectory, {
    required Directory buildOutputDirectory,
    required List<File> buildOutputFiles,
  }) {
    File('maker-called').writeAsStringSync('called');
    final maker = AppPackageMakerAppImage();
    final config = maker.configLoader.load(
      arguments,
      outputDirectory,
      buildOutputDirectory: buildOutputDirectory,
      buildOutputFiles: buildOutputFiles,
    );
    return maker.make(config);
  }
}

class PackageMethodHarness {
  final _builder = FlutterAppBuilder();
  final _packager = _LinuxPackager();
  final distributeOptions = _Options();
  final pubspec = Pubspec.parse(File('pubspec.yaml').readAsStringSync());
  final globalVariables = Map<String, String>.from(Platform.environment)
    ..remove('FLUTTER_ROOT');

  // INSERT_PRODUCTION_PACKAGE_METHOD
}

Future<void> main(List<String> arguments) async {
  final request = jsonDecode(File(arguments.single).readAsStringSync())
      as Map<String, dynamic>;
  try {
    if (request['distributor'] == true) {
      final dynamic distributor = PackageMethodHarness();
      final List<MakeResult> results = await distributor.package(
        'linux', ['appimage'], cleanBeforeBuild: false,
        buildArguments: <String, dynamic>{},
      );
      stdout.writeln('XFL_RESULT:${jsonEncode({'ok': true, 'arch': results.single.config.arch})}');
      return;
    }
    final result = BuildLinuxResult(BuildConfig());
    final arch = request.containsKey('config_arch')
        ? request['config_arch']
        : result.arch;
    final maker = AppPackageMakerAppImage();
    // This is the production BuildLinuxResult -> argument -> configLoader path.
    final config = maker.configLoader.load(
      {'build_mode': 'release', 'arch': arch},
      Directory('dist'),
      buildOutputDirectory: Directory('bundle'),
      buildOutputFiles: [],
    );
    await maker.make(config);
    stdout.writeln('XFL_RESULT:${jsonEncode({'ok': true, 'arch': config.arch})}');
  } catch (error) {
    stdout.writeln('XFL_RESULT:${jsonEncode({'ok': false, 'error': '$error', 'error_type': '${error.runtimeType}'})}');
    if (request['distributor'] == true) exitCode = 1;
  }
}
