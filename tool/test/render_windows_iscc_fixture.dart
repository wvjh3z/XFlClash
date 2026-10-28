// Render the real project template with the real flutter_distributor maker.
// Run with the activated distributor's package_config.json, not the app's.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_app_packager/src/makers/exe/inno_setup/inno_setup_script.dart';
import 'package:flutter_app_packager/src/makers/exe/make_exe_config.dart';
import 'package:yaml/yaml.dart';

import '../inject_desktop_brand.dart' as brand;
import '../windows_installer_metadata.dart';
import '../brand_identity.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError(
      'Expected repository, isolated fixture directory, manifest',
    );
  }
  final repo = Directory(args[0]).absolute.path;
  final base = Directory(args[1]).absolute;
  final manifest = File(args[2]).absolute;
  final initial = Directory.current;
  final rows = <Map<String, String>>[];
  final configSource = File(
    '$repo/windows/packaging/exe/make_config.yaml',
  ).readAsStringSync();
  final templateSource = File(
    '$repo/windows/packaging/exe/inno_setup.iss',
  ).readAsStringSync();
  try {
    for (final entry in {'brand_a': 'OmoFly', 'brand_b': '袋鼠加速'}.entries) {
      final root = Directory('${base.path}/${entry.key} 中文 space')
        ..createSync(recursive: true);
      Directory.current = root;
      final metadata = WindowsInstallerMetadata.fromYaml(
        loadYaml(
              File(
                '$repo/flavors/${entry.key}/windows_installer.yaml',
              ).readAsStringSync(),
            )
            as Map,
        defaultPublisher: entry.value,
      );
      for (final relative in [
        'windows/packaging/exe/vc_runtime.iss',
        'windows/packaging/exe/ChineseSimplified.isl',
        'windows/runner/resources/app_icon.ico',
        'tool/windows/prepare_vc_runtime.ps1',
        'tool/windows/vc_runtime.ps1',
        'tool/windows/vc_runtime.json',
        'tool/windows/stop_brand_installation.ps1',
        'tool/windows/remove_brand_user_data.ps1',
      ]) {
        File(relative).parent.createSync(recursive: true);
        File('$repo/$relative').copySync(relative);
      }
      File('windows/packaging/exe/make_config.yaml').writeAsStringSync(
        injectStableIdentity(
          injectWindowsInstallerConfig(
            brand.injectMakeConfigNames(configSource, entry.value),
            metadata,
          ),
          'windows/packaging/exe/make_config.yaml',
          brandIdentity(entry.key, root: repo),
        ),
      );
      final version = WindowsInstallerVersion(
        entry.key == 'brand_a' ? '0.1.2' : '1.2.3-rc.1+fixture',
        entry.key == 'brand_a' ? '43' : '65535',
      );
      File('windows/packaging/exe/inno_setup.iss').writeAsStringSync(
        injectWindowsInstallerVersion(
          injectStableIdentity(
            injectWindowsInstallerLinks(templateSource, metadata),
            'windows/packaging/exe/inno_setup.iss',
            brandIdentity(entry.key, root: repo),
          ),
          version,
        ),
      );
      File(
        'pubspec.yaml',
      ).writeAsStringSync('name: iscc_fixture\nversion: 0.8.93+2026052901\n');
      File('distribute_options.yaml').writeAsStringSync(
        'app_name: ${brandIdentity(entry.key, root: repo)['name']}\n',
      );
      final loader = MakeExeConfigLoader()
        ..platform = 'windows'
        ..packageFormat = 'exe';
      final config =
          loader.load(
                {'arch': 'x64', 'build_mode': 'release'},
                Directory('${root.path}/dist'),
                buildOutputDirectory: Directory('${root.path}/dummy-build'),
                buildOutputFiles: [],
              )
              as MakeExeConfig;
      // Harmless byte fixtures, never executed. /O- prevents installer output.
      File(
        '${config.packagingDirectory.path}/${config.executableName}',
      ).writeAsStringSync('preflight fixture only');
      final payload = File('build/windows-prerequisites/vc_redist.x64.exe');
      payload.parent.createSync(recursive: true);
      payload.writeAsStringSync('preflight payload only');
      final script = await InnoSetupScript.fromMakeConfig(config).createFile();
      rows.add({
        'brand': entry.key,
        'root': root.path,
        'script': script.absolute.path,
        'bundle': config.packagingDirectory.absolute.path,
        'publisher': metadata.publisherName,
        'version': version.displayVersion,
        'app_ver_name': version.appVerName.replaceAll(
          '{{DISPLAY_NAME}}',
          entry.value,
        ),
        'file_version': version.fileVersion,
        'display_name': entry.value,
      });
    }
  } finally {
    Directory.current = initial;
  }
  manifest.writeAsStringSync(jsonEncode(rows));
}
