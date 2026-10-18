// Public build inputs shared by CI and the local desktop entry. No secret export.
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:yaml/yaml.dart';

Map<String, Object> releaseContext({
  required Map flavor,
  required Map pubspec,
  required String flavorId,
  required String platform,
  required String arch,
  required String buildNumber,
  required String sourceRevision,
  required String buildTag,
  bool includeZip = false,
  bool includeRpm = true,
}) {
  String requiredText(Map document, String key) {
    final value = document[key];
    if (value is! String ||
        value.trim().isEmpty ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw FormatException('Invalid public build field: $key');
    }
    return value.trim();
  }

  final product = requiredText(flavor, 'versionName');
  final base = requiredText(pubspec, 'version').split('+').first;
  final versionPattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?(?:\+[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?$',
  );
  final number = int.tryParse(buildNumber);
  final prefix = requiredText(flavor, 'updatePackageName');
  if (!{'brand_a', 'brand_b'}.contains(flavorId) ||
      !versionPattern.hasMatch(product) ||
      !RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(base) ||
      number == null ||
      number < 1 ||
      number > 65535 ||
      number.toString() != buildNumber ||
      (sourceRevision.length != 40 ||
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(sourceRevision)) ||
      (buildTag.length != 12 || !RegExp(r'^[0-9]{12}$').hasMatch(buildTag)) ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(prefix)) {
    throw const FormatException('Invalid release identity');
  }
  final valid = platform == 'android'
      ? arch.isEmpty
      : (platform == 'windows'
            ? arch == 'amd64'
            : {'linux', 'macos'}.contains(platform) &&
                  {'amd64', 'arm64'}.contains(arch));
  if (!valid || (includeZip && platform != 'windows')) {
    throw const FormatException('Unsupported release target');
  }
  var packageName = requiredText(
    flavor,
    'appName',
  ).replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '');
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(packageName)) {
    packageName = prefix;
  }
  final targets = switch (platform) {
    'android' => ['apk'],
    'windows' => ['exe', if (includeZip) 'zip'],
    'macos' => ['dmg'],
    _ => ['deb', 'appimage', if (arch == 'amd64' && includeRpm) 'rpm'],
  };
  return {
    'schema_version': 1,
    'flavor': flavorId,
    'platform': platform,
    'arch': arch,
    'product_version': product,
    'base_version': base,
    'build_number': number,
    'source_revision': sourceRevision,
    'build_tag': buildTag,
    'package_prefix': prefix,
    'package_app_name': packageName,
    'targets': targets,
  };
}

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('flavor')
    ..addOption('platform')
    ..addOption('arch', defaultsTo: '')
    ..addOption('build-number')
    ..addOption('source-revision')
    ..addOption('build-tag')
    ..addOption('output', defaultsTo: 'build/release-context.json')
    ..addFlag('include-zip', negatable: false)
    ..addFlag('include-rpm', defaultsTo: true)
    ..addFlag('align-package-name', negatable: false);
  try {
    final options = parser.parse(args);
    final id = options['flavor'] as String? ?? '';
    if (!{'brand_a', 'brand_b'}.contains(id)) {
      throw const FormatException('Invalid flavor');
    }
    final now = DateTime.now().toUtc();
    final tag =
        options['build-tag'] as String? ??
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final data = releaseContext(
      flavor:
          loadYaml(File('flavors/$id/flavor.yaml').readAsStringSync()) as Map,
      pubspec: loadYaml(File('pubspec.yaml').readAsStringSync()) as Map,
      flavorId: id,
      platform: options['platform'] as String? ?? '',
      arch: options['arch'] as String,
      buildNumber: options['build-number'] as String? ?? '',
      sourceRevision: options['source-revision'] as String? ?? '',
      buildTag: tag,
      includeZip: options['include-zip'] as bool,
      includeRpm: options['include-rpm'] as bool,
    );
    if (options['align-package-name'] as bool) {
      final file = File('distribute_options.yaml');
      final source = file.readAsStringSync();
      final pattern = RegExp(r'^app_name:[^\r\n]*', multiLine: true);
      if (pattern.allMatches(source).length != 1) {
        throw const FormatException('Package name entry missing or ambiguous');
      }
      file.writeAsStringSync(
        source.replaceFirst(
          pattern,
          'app_name: ${jsonEncode(data['package_app_name'])}',
        ),
      );
    }
    final output = File(options['output'] as String);
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(data)}\n',
    );
    final githubEnv = Platform.environment['GITHUB_ENV'];
    if (githubEnv != null) {
      File(githubEnv).writeAsStringSync(
        'PRODUCT_VERSION=${data['product_version']}\nBASE_VERSION=${data['base_version']}\n',
        mode: FileMode.append,
      );
    }
    stdout.writeln(
      'Public release context ready: $id/${data['platform']}/${data['arch']} build ${data['build_number']}',
    );
  } catch (_) {
    // YAML parse diagnostics can embed secrets; never print the exception/input.
    stderr.writeln(
      'Release context validation failed; check public version/target fields and input files.',
    );
    exitCode = 1;
  }
}
