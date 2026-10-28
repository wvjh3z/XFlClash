import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../windows_installer_metadata.dart';

const _start = '; xboard-installer-links:start';
const _end = '; xboard-installer-links:end';
const _linkValues = {
  'publisherUrl': 'https://publisher.example.invalid/about',
  'supportUrl': 'http://support.example.invalid/help?lang=zh#contact',
  'updatesUrl': 'https://updates.example.invalid:8443/windows/latest',
};
const _directives = {
  'publisherUrl': 'AppPublisherURL',
  'supportUrl': 'AppSupportURL',
  'updatesUrl': 'AppUpdatesURL',
};

WindowsInstallerMetadata _metadata([Object? document]) =>
    WindowsInstallerMetadata.fromYaml(document, defaultPublisher: ' Omofly ');

Map<String, String?> _links(WindowsInstallerMetadata metadata) => {
  'publisherUrl': metadata.publisherUrl,
  'supportUrl': metadata.supportUrl,
  'updatesUrl': metadata.updatesUrl,
};

void main() {
  test(
    'both brands inject publisher into the tracked config without a dummy default',
    () {
      final source = File(
        'windows/packaging/exe/make_config.yaml',
      ).readAsStringSync();
      expect(
        (loadYaml(source) as YamlMap).containsKey('publisher_name'),
        isFalse,
      );
      expect(source, isNot(contains('MyClient')));
      for (final brand in {'brand_a': 'Omofly', 'brand_b': 'Daishu'}.entries) {
        final metadata = WindowsInstallerMetadata.fromYaml(
          loadYaml(
            File(
              'flavors/${brand.key}/windows_installer.yaml',
            ).readAsStringSync(),
          ),
          defaultPublisher: brand.value,
        );
        final injected = injectWindowsInstallerConfig(source, metadata);
        expect((loadYaml(injected) as YamlMap)['publisher_name'], brand.value);
        expect(injectWindowsInstallerConfig(injected, metadata), injected);
      }
    },
  );
  group('Installer product version and actual build', () {
    final template = File(
      'windows/packaging/exe/inno_setup.iss',
    ).readAsStringSync();
    test('version directives ignore upstream version and remain idempotent', () {
      final version = WindowsInstallerVersion('1.2.3-rc.1+channel', '65535');
      final result = injectWindowsInstallerVersion(template, version);
      expect(result, contains('AppVersion=1.2.3-rc.1+channel (build 65535)'));
      expect(result, contains('VersionInfoVersion=1.2.3.65535'));
      expect(
        result,
        contains(
          'AppVerName={{DISPLAY_NAME}} 1.2.3-rc.1+channel ({cm:XbBuildLabel} 65535)',
        ),
      );
      expect(result, isNot(contains('{{APP_VERSION}}')));
      expect(result, isNot(contains('#error "Run inject_desktop_brand')));
      expect(injectWindowsInstallerVersion(result, version), result);
      final switched = injectWindowsInstallerVersion(
        result,
        WindowsInstallerVersion('0.0.1', '30'),
      );
      expect(switched, contains('AppVersion=0.0.1 (build 30)'));
      final versionBlock = RegExp(
        r'; xboard-installer-version:start[\s\S]*?; xboard-installer-version:end',
      );
      expect(
        versionBlock.firstMatch(switched)!.group(0),
        isNot(contains('65535')),
      );
      // Other domains may legitimately use the same number (e.g. TCP port max).
      expect(
        switched.replaceAll(versionBlock, ''),
        template.replaceAll(versionBlock, ''),
      );
      expect(
        switched.substring(switched.indexOf('[Tasks]')),
        template.substring(template.indexOf('[Tasks]')),
      );
      expect(switched, contains('AppId={{APP_ID}}'));
    });
    for (final value in [
      '',
      '0',
      '-1',
      '1.1',
      '01',
      '65536',
      '999999999999999',
      '1\nAppId=bad',
      '30\n',
    ]) {
      test('reject invalid actual build number ${value.length}/$value', () {
        expect(
          () => WindowsInstallerVersion('0.0.1', value),
          throwsFormatException,
        );
      });
    }
    for (final value in [
      '',
      '1.2',
      '01.2.3',
      '65536.0.0',
      '0.0.1\nAppId=bad',
      '{app}',
      '{{APP_VERSION}}',
      '0.0.1"',
      '0.0.1\n',
      '0.0.1-..',
    ]) {
      test('reject invalid product version ${value.length}/$value', () {
        expect(
          () => WindowsInstallerVersion(value, '30'),
          throwsFormatException,
        );
      });
    }
    test(
      'missing duplicate reversed or outside version directives fail closed',
      () {
        for (final value in [
          template.replaceAll('; xboard-installer-version:start', ''),
          '$template\n; xboard-installer-version:end\n',
          '; xboard-installer-version:end\n; xboard-installer-version:start\n',
          '$template\nAppVersion=old\n',
        ]) {
          expect(
            () => injectWindowsInstallerVersion(
              value,
              WindowsInstallerVersion('0.0.1', '30'),
            ),
            throwsFormatException,
          );
        }
      },
    );
  });
  group('Windows installer metadata configuration', () {
    test(
      'missing, empty and YAML mappings use the trimmed publisher fallback',
      () {
        for (final document in <Object?>[
          null,
          <String, Object?>{},
          loadYaml('# No optional installer metadata configured.\n'),
          loadYaml('{}'),
          {'publisherName': null},
          {'publisherName': '   '},
        ]) {
          final metadata = _metadata(document);
          expect(metadata.publisherName, 'Omofly');
          expect(_links(metadata).values, everyElement(isNull));
        }
      },
    );

    test('YAML publisher and independent HTTP/HTTPS URLs are trimmed', () {
      final metadata = _metadata(
        loadYaml('''
publisherName: ' Daishu '
publisherUrl: ' ${_linkValues['publisherUrl']} '
supportUrl: '${_linkValues['supportUrl']}'
updatesUrl: '${_linkValues['updatesUrl']}'
'''),
      );
      expect(metadata.publisherName, 'Daishu');
      expect(_links(metadata), _linkValues);
    });

    test('null and whitespace URL values remain absent', () {
      final metadata = _metadata({
        'publisherUrl': null,
        'supportUrl': '  ',
        'updatesUrl': '',
      });
      expect(_links(metadata).values, everyElement(isNull));
    });

    test(
      'unknown keys and non-mapping documents fail instead of being ignored',
      () {
        for (final document in <Object?>[
          'publisherName: Omofly',
          42,
          true,
          ['Omofly'],
          {'publisher': 'Omofly'},
          {'publisherURL': 'https://example.invalid'},
          {1: 'Omofly'},
        ]) {
          expect(() => _metadata(document), throwsFormatException);
        }
      },
    );

    for (final field in ['publisherName', ..._linkValues.keys]) {
      test('$field rejects non-string YAML values', () {
        for (final value in <Object>[
          42,
          false,
          ['https://example.invalid'],
          {'value': 'https://example.invalid'},
        ]) {
          expect(() => _metadata({field: value}), throwsFormatException);
        }
      });
    }

    test('publisher rejects control characters and Inno constants', () {
      for (final value in [
        'Omo\nfly',
        'Omo\rfly',
        'Omo\tfly',
        'Omo\u0000fly',
        'Omo\u007ffly',
        '{app}',
        'Omofly}',
      ]) {
        expect(
          () => _metadata({'publisherName': value}),
          throwsFormatException,
        );
      }
    });

    for (final field in _linkValues.keys) {
      test(
        '$field rejects invalid or unsafe addresses without exposing input',
        () {
          for (final value in [
            'installer-secret-marker',
            '/relative/installer-secret-marker',
            '//example.invalid/installer-secret-marker',
            'ftp://example.invalid/installer-secret-marker',
            'file:///installer-secret-marker',
            'https:///installer-secret-marker',
            'https://user:installer-secret-marker@example.invalid/',
            'https://example.invalid/installer-secret-marker with-space',
            'https://example.invalid/installer-secret-marker\nAppName=Injected',
            'https://example.invalid/installer-secret-marker\u0000',
            'https://example.invalid/{installer-secret-marker}',
          ]) {
            expect(
              () => _metadata({field: value}),
              throwsA(
                isA<FormatException>().having(
                  (error) => error.toString(),
                  'safe diagnostic',
                  isNot(contains('installer-secret-marker')),
                ),
              ),
            );
          }
        },
      );
    }
  });

  group('Installer links injection', () {
    const prefix =
        '[Setup]\nAppId={{APP_ID}}\nAppPublisher={{PUBLISHER_NAME}}\n';
    const suffix =
        '\nUsePreviousTasks=no\n[Tasks]\nName: "desktopicon"; '
        'Flags: checkedonce\n';
    const source =
        '$prefix$_start\n'
        'AppPublisherURL=https://old.example.invalid\n'
        'AppSupportURL=https://old.example.invalid\n'
        'AppUpdatesURL=https://old.example.invalid\n'
        '$_end$suffix';

    for (var selection = 0; selection < 8; selection++) {
      test('each URL is independently optional (selection $selection)', () {
        final configured = <String, Object?>{};
        for (var index = 0; index < _linkValues.length; index++) {
          if ((selection & (1 << index)) != 0) {
            final field = _linkValues.keys.elementAt(index);
            configured[field] = _linkValues[field];
          }
        }
        final metadata = _metadata(configured);
        final result = injectWindowsInstallerLinks(source, metadata);

        expect(result, startsWith('$prefix$_start'));
        expect(result, endsWith('$_end$suffix'));
        expect(result, isNot(contains('old.example.invalid')));
        for (final field in _linkValues.keys) {
          final directive = _directives[field]!;
          final lines = result
              .split('\n')
              .where((line) => line.startsWith('$directive='));
          expect(
            lines,
            configured.containsKey(field)
                ? ['$directive=${_linkValues[field]}']
                : isEmpty,
          );
        }
        expect(injectWindowsInstallerLinks(result, metadata), result);
      });
    }

    test(
      'brand switch replaces links and unconfigured brand clears all links',
      () {
        final brandA = injectWindowsInstallerLinks(
          source,
          _metadata(_linkValues),
        );
        final brandB = injectWindowsInstallerLinks(
          brandA,
          _metadata({
            'publisherName': 'Daishu',
            'supportUrl': 'https://brand-b.example.invalid/support',
          }),
        );
        expect(
          brandB,
          contains('AppSupportURL=https://brand-b.example.invalid/'),
        );
        expect(brandB, isNot(contains('AppPublisherURL=')));
        expect(brandB, isNot(contains('AppUpdatesURL=')));
        for (final address in _linkValues.values) {
          expect(brandB, isNot(contains(address)));
        }
        final cleared = injectWindowsInstallerLinks(brandB, _metadata());
        expect(cleared, isNot(contains('brand-b.example.invalid')));
        for (final directive in _directives.values) {
          expect(cleared, isNot(contains('$directive=')));
        }
      },
    );

    test('missing, repeated and reversed markers fail closed', () {
      for (final broken in [
        '[Setup]\nAppId={{APP_ID}}\n',
        '$_start\n',
        '$_end\n',
        '$_end\n$_start\n',
        '$_start\n$_start\n$_end\n',
        '$_start\n$_end\n$_end\n',
        '$_start\n$_end\n$_start\n$_end\n',
      ]) {
        expect(
          () => injectWindowsInstallerLinks(broken, _metadata()),
          throwsFormatException,
        );
      }
    });
  });

  group('Installer configuration and repository fixtures', () {
    test(
      'legacy publisher keys are removed while installer identity survives',
      () {
        const source = r'''
script_template: inno_setup.iss
app_id: 9F3A1C2E-7B4D-4E6A-9C12-A1B2C3D4E5F6
app_name: Custom Client
display_name: Custom Client
executable_name: FlClash.exe
publisher: Legacy
publisher_url: https://old.example.invalid
appPublisher: Legacy
appPublisherUrl: https://old.example.invalid
publisher_name: Legacy
create_desktop_icon: false
privileges_required: admin
locales:
  - lang: zh
    file: ..\windows\packaging\exe\ChineseSimplified.isl
''';
        final result = injectWindowsInstallerConfig(source, _metadata());
        final before = Map<Object?, Object?>.from(loadYaml(source) as Map);
        final after = loadYaml(result) as YamlMap;
        for (final key in [
          'publisher',
          'publisher_url',
          'appPublisher',
          'appPublisherUrl',
        ]) {
          expect(after.containsKey(key), isFalse);
          before.remove(key);
        }
        before['publisher_name'] = 'Omofly';
        expect(after, before);
        expect(injectWindowsInstallerConfig(result, _metadata()), result);
        final switched = injectWindowsInstallerConfig(
          result,
          _metadata({'publisherName': 'Daishu'}),
        );
        expect((loadYaml(switched) as YamlMap)['publisher_name'], 'Daishu');
        expect(switched, isNot(contains('Omofly')));
      },
    );

    test(
      'tracked brands specify their publisher and omit unconfigured links',
      () {
        for (final brand in {
          'brand_a': 'Omofly',
          'brand_b': 'Daishu',
        }.entries) {
          final source = File(
            'flavors/${brand.key}/windows_installer.yaml',
          ).readAsStringSync();
          final metadata = _metadata(loadYaml(source));
          expect(metadata.publisherName, brand.value);
          expect(_links(metadata).values, everyElement(isNull));
        }
      },
    );

    test(
      'tracked installer identity, task choices and placeholders survive',
      () {
        final config = File(
          'windows/packaging/exe/make_config.yaml',
        ).readAsStringSync();
        final template = File(
          'windows/packaging/exe/inno_setup.iss',
        ).readAsStringSync();
        final before = loadYaml(config) as YamlMap;
        final injectedConfig = injectWindowsInstallerConfig(
          config,
          _metadata(),
        );
        final after = loadYaml(injectedConfig) as YamlMap;
        expect(after['app_id'], '9F3A1C2E-7B4D-4E6A-9C12-A1B2C3D4E5F6');
        for (final field in [
          'script_template',
          'app_id',
          'app_name',
          'display_name',
          'executable_name',
          'create_desktop_icon',
          'privileges_required',
          'locales',
        ]) {
          expect(after[field], before[field], reason: 'Preserve $field');
        }
        expect(after['publisher_name'], 'Omofly');
        final injectedTemplate = injectWindowsInstallerLinks(
          template,
          _metadata(),
        );
        expect(injectedTemplate, contains('AppId={{APP_ID}}'));
        expect(injectedTemplate, contains('AppPublisher={{PUBLISHER_NAME}}'));
        expect(injectedTemplate, contains('UsePreviousTasks=no'));
        expect(
          injectedTemplate.substring(injectedTemplate.indexOf('[Tasks]')),
          template.substring(template.indexOf('[Tasks]')),
        );
        for (final directive in _directives.values) {
          expect(injectedTemplate, isNot(contains('$directive=')));
        }
      },
    );
  });
}
