// Execute the pinned APK maker only: harmless files, no Flutter/Gradle/network.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_app_packager/src/api/make_config.dart';
import 'package:flutter_app_packager/src/makers/apk/app_package_maker_apk.dart';

Future<void> main(List<String> args) async {
  final base = Directory(args.single).absolute;
  for (final brand in {'brand_a': 'OmoFly', 'brand_b': 'ds'}.entries) {
    final root = Directory('${base.path}/${brand.key}')
      ..createSync(recursive: true);
    Directory.current = root;
    File(
      'pubspec.yaml',
    ).writeAsStringSync('name: fixture\nversion: 0.8.93+2026052901\n');
    File(
      'distribute_options.yaml',
    ).writeAsStringSync('app_name: ${brand.value}\n');
    final input = Directory('input')..createSync();
    final files = [
      for (final abi in ['armeabi-v7a', 'arm64-v8a'])
        File('input/app-$abi-${brand.key}-release.apk')
          ..writeAsStringSync('harmless fixture ${brand.key} $abi'),
    ];
    final config = MakeConfig()
      ..platform = 'android'
      ..buildMode = 'release'
      ..flavor = brand.key
      ..packageFormat = 'apk'
      ..buildOutputDirectory = input
      ..buildOutputFiles = files
      ..outputDirectory = Directory('dist');
    await AppPackageMakerApk().make(config);
    // Inspect physical copies, not MakeResult's generic base output path.
    print(
      jsonEncode({
        'flavor': brand.key,
        'files': Directory(
          'dist',
        ).listSync().map((file) => file.uri.pathSegments.last).toList(),
      }),
    );
  }
}
