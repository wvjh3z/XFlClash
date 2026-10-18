// Exercise the real CLI against public, isolated fixtures; no pub or builds.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

final _repository = Directory.current.path;
final _script = p.join(_repository, 'tool/inject_desktop_brand.dart');
final _packages = p.join(_repository, '.dart_tool/package_config.json');
const _textInputs = [
  'windows/runner/main.cpp',
  'windows/runner/Runner.rc',
  'linux/runner/my_application.cc',
  'macos/Runner/Configs/AppInfo.xcconfig',
  'macos/Runner/Info.plist',
  'macos/Runner.xcodeproj/project.pbxproj',
  'macos/packaging/dmg/make_config.yaml',
  'linux/packaging/appimage/make_config.yaml',
  'linux/packaging/rpm/make_config.yaml',
  'linux/packaging/deb/make_config.yaml',
  'windows/packaging/exe/make_config.yaml',
  'windows/packaging/exe/inno_setup.iss',
];

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('system_icon_cli_');
    for (final path in [
      ..._textInputs,
      'assets/images/icon.png',
      for (var state = 1; state <= 3; state++) ...[
        'assets/images/icon/status_$state.png',
        'assets/images/icon/status_$state.ico',
      ],
    ]) {
      _copyFile(path, project);
    }
    for (final brand in ['brand_a', 'brand_b']) {
      _copyFile('flavors/$brand/windows_installer.yaml', project);
      _copyFile('flavors/$brand/assets/icons/$brand.png', project);
      final systemIcons = Directory(
        p.join(_repository, 'flavors', brand, 'system_icons'),
      );
      for (final entity in systemIcons.listSync(recursive: true)) {
        if (entity is File) {
          _copyFile(p.relative(entity.path, from: _repository), project);
        }
      }
      File(
        p.join(project.path, 'flavors', brand, 'flavor.yaml'),
      ).writeAsStringSync('appName: "Fixture $brand"\nversionName: 0.1.2\n');
    }
  });

  tearDown(() => project.deleteSync(recursive: true));

  Future<ProcessResult> inject(
    String brand,
    String platform, {
    bool check = false,
    String? buildNumber = '43',
  }) => Process.run('dart', [
    '--packages=$_packages',
    _script,
    '--flavor',
    brand,
    '--platform',
    platform,
    if (buildNumber != null) ...['--build-number', buildNumber],
    if (check) '--check',
  ], workingDirectory: project.path);

  test('Windows actual build number is required before any mutation', () async {
    final before = File(
      p.join(project.path, 'windows/packaging/exe/inno_setup.iss'),
    ).readAsStringSync();
    for (final number in <String?>[null, '', '0', '65536', 'x']) {
      final result = await inject('brand_a', 'windows', buildNumber: number);
      expect(result.exitCode, isNot(0));
      expect(
        File(
          p.join(project.path, 'windows/packaging/exe/inno_setup.iss'),
        ).readAsStringSync(),
        before,
      );
    }
  });

  test(
    'Windows A/B/A actual CLI reinjects product version and build without stale values',
    () async {
      for (final brand in ['brand_a', 'brand_b', 'brand_a']) {
        final version = brand == 'brand_a' ? '0.2.3' : '1.2.3-rc.1+test';
        final number = brand == 'brand_a' ? '31' : '52';
        File(
          p.join(project.path, 'flavors/$brand/flavor.yaml'),
        ).writeAsStringSync(
          'appName: "Fixture $brand"\nversionName: $version\n',
        );
        final result = await inject(brand, 'windows', buildNumber: number);
        expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
        final file = File(
          p.join(project.path, 'windows/packaging/exe/inno_setup.iss'),
        );
        final first = file.readAsStringSync();
        expect(first, contains('AppVersion=$version (build $number)'));
        expect(
          first,
          contains(
            'AppVerName={{DISPLAY_NAME}} $version ({cm:XbBuildLabel} $number)',
          ),
        );
        expect(first, isNot(contains('{{APP_VERSION}}')));
        expect(first, isNot(contains('2026052901')));
        final repeated = await inject(brand, 'windows', buildNumber: number);
        expect(repeated.exitCode, 0);
        expect(file.readAsStringSync(), first);
      }
    },
  );

  for (final brand in ['brand_a', 'brand_b']) {
    test(
      '$brand CLI injects each platform and replaces shared PNGs on switch',
      () async {
        // Linux -> macOS -> Linux checks both directions of the shared PNG path.
        for (final platform in ['linux', 'macos', 'linux', 'windows']) {
          final before = {
            for (var state = 1; state <= 3; state++)
              for (final extension in ['png', 'ico'])
                'status_$state.$extension': File(
                  p.join(
                    project.path,
                    'assets/images/icon/status_$state.$extension',
                  ),
                ).readAsBytesSync(),
          };
          final result = await inject(brand, platform);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          final extension = platform == 'windows' ? 'ico' : 'png';
          final written = {
            for (final state in platform == 'macos' ? [1] : [1, 2, 3])
              'status_$state.$extension',
          };
          for (final entry in before.entries) {
            final actual = File(
              p.join(project.path, 'assets/images/icon', entry.key),
            ).readAsBytesSync();
            final expected = written.contains(entry.key)
                ? File(
                    p.join(
                      _repository,
                      'flavors',
                      brand,
                      'system_icons',
                      platform,
                      entry.key,
                    ),
                  ).readAsBytesSync()
                : entry.value;
            expect(
              actual,
              orderedEquals(expected),
              reason: '$platform / ${entry.key}',
            );
          }
          expect(
            File(
              p.join(project.path, 'windows/runner/main.cpp'),
            ).readAsStringSync(),
            contains('L"Fixture $brand"'),
          );
          expect(
            File(
              p.join(project.path, 'assets/images/icon.png'),
            ).readAsBytesSync(),
            orderedEquals(
              File(
                p.join(_repository, 'flavors/$brand/assets/icons/$brand.png'),
              ).readAsBytesSync(),
            ),
          );
        }
      },
    );
  }

  test(
    'macOS CLI keeps current A/B bundle and DMG names in sync on switch',
    () async {
      // Public display names; private flavor files are absent in clean checkouts.
      const names = {'brand_a': 'OmoFly', 'brand_b': '袋鼠加速'};
      for (final brand in ['brand_a', 'brand_b']) {
        File(
          p.join(project.path, 'flavors/$brand/flavor.yaml'),
        ).writeAsStringSync('appName: "${names[brand]}"\n');
      }
      String read(String path) =>
          File(p.join(project.path, path)).readAsStringSync();
      final originalProject = read('macos/Runner.xcodeproj/project.pbxproj');
      final originalInfo = read('macos/Runner/Info.plist');
      final bundleIdentifier = RegExp(
        r'^PRODUCT_BUNDLE_IDENTIFIER\s*=.*$',
        multiLine: true,
      ).firstMatch(read('macos/Runner/Configs/AppInfo.xcconfig'))!.group(0);

      for (final brand in ['brand_a', 'brand_b', 'brand_a']) {
        final result = await inject(brand, 'macos');
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final name = names[brand]!;
        final appInfo = read('macos/Runner/Configs/AppInfo.xcconfig');
        expect(
          RegExp(
            r'^PRODUCT_NAME\s*=\s*(.*)$',
            multiLine: true,
          ).firstMatch(appInfo)?.group(1),
          name,
        );
        expect(appInfo, contains(bundleIdentifier!));
        final info = read('macos/Runner/Info.plist');
        for (final key in ['CFBundleDisplayName', 'CFBundleName']) {
          expect(
            RegExp(
              '<key>$key</key>\\s*<string>([^<]*)</string>',
            ).firstMatch(info)?.group(1),
            r'$(PRODUCT_NAME)',
            reason: '$brand / $key',
          );
        }
        for (final key in [
          'CFBundleIdentifier',
          'CFBundleExecutable',
          'CFBundleURLTypes',
        ]) {
          final value = RegExp(
            '<key>$key</key>\\s*(<string>[^<]*</string>|<array>[\\s\\S]*?</array>\\s*</dict>\\s*</array>)',
          );
          expect(value.firstMatch(info)?.group(1), isNotNull, reason: key);
          expect(
            value.firstMatch(info)?.group(1),
            value.firstMatch(originalInfo)?.group(1),
          );
        }
        expect(read('macos/Runner.xcodeproj/project.pbxproj'), originalProject);
        final dmg =
            loadYaml(read('macos/packaging/dmg/make_config.yaml')) as YamlMap;
        expect(dmg['title'], name);
        final appEntry = (dmg['contents'] as YamlList)
            .cast<YamlMap>()
            .singleWhere((entry) => entry['type'] == 'file');
        expect(appEntry['path'], '$name.app');

        final before = {for (final path in _textInputs) path: read(path)};
        final repeated = await inject(brand, 'macos');
        expect(
          repeated.exitCode,
          0,
          reason: '${repeated.stdout}\n${repeated.stderr}',
        );
        expect({for (final path in _textInputs) path: read(path)}, before);
      }
    },
  );

  test(
    '--check reports planned changes without writing any project entry',
    () async {
      final before = _snapshot(project);
      final result = await inject('brand_a', 'macos', check: true);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('assets/images/icon/status_1.png'));
      expect(_snapshot(project), before);
      expect(
        File(p.join(project.path, 'flutter_launcher_icons.yaml')).existsSync(),
        isFalse,
      );
    },
  );

  for (final missing in [true, false]) {
    test(
      '${missing ? 'missing resource' : 'stale source'} fails before writes',
      () async {
        if (missing) {
          File(
            p.join(
              project.path,
              'flavors/brand_a/system_icons/linux/status_3.png',
            ),
          ).deleteSync();
        } else {
          final source = File(
            p.join(project.path, 'flavors/brand_a/system_icons/monochrome.svg'),
          );
          source.writeAsStringSync('${source.readAsStringSync()}\n');
        }
        final before = _snapshot(project);
        // A missing Linux input must also stop a Windows preparation.
        final result = await inject('brand_a', 'windows');
        expect(result.exitCode, 1);
        expect(result.stderr, contains('系统图标'));
        expect(_snapshot(project), before);
      },
    );
  }

  test('an unsupported platform is a usage error with no writes', () async {
    final before = _snapshot(project);
    final result = await inject('brand_a', 'android');
    expect(result.exitCode, 2);
    expect(result.stderr, contains('platform'));
    expect(_snapshot(project), before);
  });
}

void _copyFile(String relative, Directory target) {
  final destination = File(p.join(target.path, relative));
  destination.parent.createSync(recursive: true);
  File(p.join(_repository, relative)).copySync(destination.path);
}

Map<String, String> _snapshot(Directory root) => {
  for (final entity in root.listSync(recursive: true, followLinks: false))
    p.relative(entity.path, from: root.path): entity is File
        ? '${entity.lastModifiedSync().microsecondsSinceEpoch}:'
              '${sha256.convert(entity.readAsBytesSync())}'
        : 'directory:${entity.statSync().modified.microsecondsSinceEpoch}',
};
