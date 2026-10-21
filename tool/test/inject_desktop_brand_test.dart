// inject_desktop_brand 纯变换契约测试（真实文件片段 + 幂等）。
// 跑：dart test tool/test/inject_desktop_brand_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'package:test/test.dart';

import '../inject_desktop_brand.dart';

void main() {
  const app = 'OmoFly';

  group('Runner branding survives real Git checkout', () {
    late _RunnerCheckoutFixture fixture;
    setUpAll(() {
      fixture = _RunnerCheckoutFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      fixture.initialize();
    });
    for (final autocrlf in ['false', 'input', 'true']) {
      test('core.autocrlf=$autocrlf preserves all three configurations', () {
        final checkout = fixture.checkout(autocrlf);
        final file = File(p.join(checkout.path, _runnerProject));
        final bytes = file.readAsBytesSync();
        final project = utf8.decode(bytes);
        final crlf = autocrlf == 'true';
        expect(project.contains('\r\n'), crlf);
        expect(
          project,
          crlf ? fixture.canonical.replaceAll('\n', '\r\n') : fixture.canonical,
        );
        _expectRunnerBrandConfiguration(project);
        expect(
          file.readAsBytesSync(),
          orderedEquals(bytes),
          reason: 'Validation must not rewrite checkout',
        );
        expect(fixture.git(checkout, ['status', '--porcelain']), isEmpty);
      });
    }
    test('CRLF checkout reproduces the old LF-only regex failure', () {
      final project = File(
        p.join(fixture.checkout('true').path, _runnerProject),
      ).readAsStringSync();
      final old = RegExp(
        r'buildSettings = \{([\s\S]*?)\n\t\t\t\};\n\t\t\tname = (\w+);',
      );
      expect(project.contains('\r\n'), isTrue);
      expect(old.allMatches(project), isEmpty);
      _expectRunnerBrandConfiguration(project);
    });
    test(
      'real checkout still rejects missing configurations and wrong display names',
      () {
        for (final mode in ['false', 'true']) {
          final project = File(
            p.join(fixture.checkout(mode).path, _runnerProject),
          ).readAsStringSync();
          expect(
            () => _expectRunnerBrandConfiguration(
              project.replaceAll('name = Debug;', 'name = Renamed;'),
            ),
            throwsA(isA<TestFailure>()),
          );
          expect(
            () => _expectRunnerBrandConfiguration(
              project.replaceAll(
                r'INFOPLIST_KEY_CFBundleDisplayName = "$(PRODUCT_NAME)";',
                'INFOPLIST_KEY_CFBundleDisplayName = FlClash;',
              ),
            ),
            throwsA(isA<TestFailure>()),
          );
        }
      },
    );
  });

  test('Windows 窗口标题', () {
    const src = '  if (!window.Create(L"FlClash", origin, size)) {';
    final out = injectWindowsTitle(src, app);
    expect(out, contains('L"OmoFly"'));
    expect(out, isNot(contains('FlClash')));
    expect(injectWindowsTitle(out, app), out); // 幂等
  });

  group('Windows Unicode title injection', () {
    const source = 'if (!window.Create(L"FlClash", origin, size)) {';
    test('Chinese and supplementary characters become fixed-width escapes', () {
      final chinese = injectWindowsTitle(source, '袋鼠加速');
      expect(chinese, contains(r'L"\u888B\u9F20\u52A0\u901F"'));
      expect(chinese.codeUnits.every((unit) => unit < 128), isTrue);
      expect(injectWindowsTitle(chinese, '袋鼠加速'), chinese);
      expect(injectWindowsTitle(source, '袋鼠 🦘'), contains(r'\U0001F998'));
    });
    test(
      'quotes and literal Unicode-looking backslashes survive reinjection',
      () {
        const name = r'袋鼠 "Pro" \u888B\path';
        final injected = injectWindowsTitle(source, name);
        expect(injected, contains(r'\"Pro\" \\u888B\\path'));
        expect(injectWindowsTitle(injected, name), injected);
        expect(
          injectWindowsTitle(injected, app),
          'if (!window.Create(L"OmoFly", origin, size)) {',
        );
      },
    );
    test('LF/CRLF and brand switching preserve surrounding source', () {
      for (final newline in ['\n', '\r\n']) {
        final original = '// header$newline$source$newline// tail';
        final b = injectWindowsTitle(original, '袋鼠加速');
        expect(b, startsWith('// header$newline'));
        expect(b, endsWith('$newline// tail'));
        expect(
          injectWindowsTitle(b, app),
          original.replaceFirst('FlClash', app),
        );
      }
    });
    test('complete argument accepts whitespace and preserves reinjection', () {
      for (final separator in [' ', '\t', '\n  ', '\r\n  ']) {
        final original = source.replaceFirst('",', '"$separator,');
        final injected = injectWindowsTitle(original, '袋鼠加速');
        expect(injected, contains('"$separator,'));
        expect(injectWindowsTitle(injected, '袋鼠加速'), injected);
        expect(
          injectWindowsTitle(injected, app),
          original.replaceFirst('FlClash', app),
        );
      }
    });
    test('partial literals and mixed valid/invalid calls are rejected', () {
      for (final argument in [
        'L"Fl" L"Clash"',
        'L"Fl" "Clash"',
        'L"Fl"\nL"Clash"',
        'L"Fl"\r\nL"Clash"',
        'L"FlClash" + suffix',
        'L"FlClash"s.c_str()',
      ]) {
        final invalid = source.replaceFirst('L"FlClash"', argument);
        for (final text in [invalid, '$source\n$invalid', '$invalid\n$source']) {
          expect(
            () => injectWindowsTitle(text, app),
            throwsFormatException,
            reason: argument,
          );
        }
      }
      expect(
        () => injectWindowsTitle('window.Create(L"FlClash")', app),
        throwsFormatException,
      );
    });
    test('invalid names and ambiguous source fail before writing', () {
      for (final name in [
        '',
        ' ',
        'bad\nname',
        'bad\u0000name',
        'bad\u007fname',
        String.fromCharCode(0xd800),
      ]) {
        expect(() => injectWindowsTitle(source, name), throwsFormatException);
      }
      for (final text in [
        '',
        source + source,
        r'if (!window.Create("FlClash", origin, size)) {',
      ]) {
        expect(() => injectWindowsTitle(text, app), throwsFormatException);
      }
    });
  });

  test('Windows Runner.rc FileDescription（不动 ProductName/InternalName）', () {
    const src =
        '            VALUE "FileDescription", "FlClash" "\\0"\n'
        '            VALUE "ProductName", "clash" "\\0"\n'
        '            VALUE "InternalName", "clash" "\\0"';
    final out = injectWindowsRc(src, app);
    expect(out, contains('"FileDescription", "OmoFly"'));
    expect(out, contains('"ProductName", "clash"')); // 不动
    expect(out, contains('"InternalName", "clash"')); // 不动
    expect(injectWindowsRc(out, app), out);
  });

  test('Linux 窗口标题（header_bar + window 两处）', () {
    const src =
        '    gtk_header_bar_set_title(header_bar, "FlClash");\n'
        '    gtk_window_set_title(window, "FlClash");';
    final out = injectLinuxTitle(src, app);
    expect('OmoFly'.allMatches(out).length, 2);
    expect(out, isNot(contains('"FlClash"')));
    expect(injectLinuxTitle(out, app), out);
  });

  test('macOS PRODUCT_NAME', () {
    const src =
        '// comment\nPRODUCT_NAME = FlClash\n'
        'PRODUCT_BUNDLE_IDENTIFIER = com.follow.clash';
    final out = injectMacProductName(src, app);
    expect(out, contains('PRODUCT_NAME = OmoFly'));
    expect(out, contains('PRODUCT_BUNDLE_IDENTIFIER = com.follow.clash')); // 不动
    expect(injectMacProductName(out, app), out);
  });

  test('macOS 显示名与 Bundle 名共用 PRODUCT_NAME，无本地化覆盖', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    for (final key in ['CFBundleDisplayName', 'CFBundleName']) {
      expect(
        RegExp(
          '<key>$key</key>\\s*<string>([^<]*)</string>',
        ).firstMatch(plist)?.group(1),
        r'$(PRODUCT_NAME)',
        reason: key,
      );
    }
    final project = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    _expectRunnerBrandConfiguration(project);
    expect(
      Directory('macos/Runner')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last == 'InfoPlist.strings'),
      isEmpty,
      reason: '本地化显示名不能覆盖品牌 PRODUCT_NAME',
    );
  });

  test('macOS PRODUCT_NAME 保留中文与文件名标点并可重复切换', () {
    const source =
        'PRODUCT_NAME = FlClash\n'
        'PRODUCT_BUNDLE_IDENTIFIER = com.follow.clash\n';
    var current = source;
    for (final name in ['OmoFly', '袋鼠加速', '袋鼠加速-Pro_2.0', 'OmoFly']) {
      current = injectMacProductName(current, name);
      expect(
        current,
        'PRODUCT_NAME = $name\n'
        'PRODUCT_BUNDLE_IDENTIFIER = com.follow.clash\n',
      );
      expect(injectMacProductName(current, name), current);
    }
  });

  test('macOS Info.plist 定位权限文案（不动 URL scheme flclash）', () {
    const src =
        '<string>flclash</string>\n'
        '<key>NSLocationWhenInUseUsageDescription</key>\n'
        '<string>FlClash needs location access to detect WiFi network name.</string>';
    final out = injectMacInfoPlist(src, app);
    expect(out, contains('<string>OmoFly needs location access'));
    expect(out, contains('<string>flclash</string>')); // URL scheme 不动
    expect(injectMacInfoPlist(out, app), out);
  });

  test('macOS dmg make_config（title + .app 路径）', () {
    const src =
        'title: FlClash\ncontents:\n  - type: file\n    path: FlClash.app\n';
    final out = injectDmgMakeConfig(src, app);
    expect(out, contains('title: OmoFly'));
    expect(out, contains('path: OmoFly.app'));
    expect(out, isNot(contains('FlClash')));
    expect(injectDmgMakeConfig(out, app), out);
  });

  test('通用 make_config 显示名（display_name/generic_name/keywords 外）', () {
    const src =
        'display_name: FlClash\napp_name: MyClient\n'
        'generic_name: FlClash\npublisher: chen08209\napp_id: ABC-123\n';
    final out = injectMakeConfigNames(src, app);
    expect(out, contains('display_name: OmoFly'));
    expect(out, contains('app_name: OmoFly')); // 从 MyClient 也统一过来
    expect(out, contains('generic_name: OmoFly'));
    expect(out, contains('publisher: chen08209')); // 不动
    expect(out, contains('app_id: ABC-123')); // 不动
    expect(injectMakeConfigNames(out, app), out);
  });

  group('AppImage brand keyword injection', () {
    final source = File('linux/packaging/appimage/make_config.yaml').readAsStringSync();
    late _RunnerCheckoutFixture fixture;
    setUpAll(() {
      fixture = _RunnerCheckoutFixture(sourcePath: _appImageConfig);
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      fixture.initialize();
    });
    for (final brand in ['OmoFly', '袋鼠加速']) {
      for (final crlf in [false, true]) {
        test('$brand actual template, CRLF=$crlf and repeated injection', () {
          final input = _fixtureLineEndings(source, crlf: crlf);
          final result = injectAppImageBrand(input, brand);
          final doc = loadYaml(result) as YamlMap;
          final original = loadYaml(source) as YamlMap;
          expect(doc['keywords'], [brand, 'Clash', 'ClashMeta', 'Proxy']);
          expect(doc['display_name'], brand);
          expect(doc['generic_name'], brand);
          for (final key in original.keys.where((k) => !['keywords', 'display_name', 'generic_name'].contains(k))) {
            expect(doc[key], original[key]);
          }
          expect(injectAppImageBrand(result, brand), result);
          expect(result, isNot(contains('MyClient')));
        });
      }
    }
    for (final mode in ['false', 'input', 'true']) {
      test('real AppImage Git checkout autocrlf=$mode supports both brands and fixture line endings', () {
        final checkout = fixture.checkout(mode);
        final file = File(p.join(checkout.path, _appImageConfig));
        final bytes = file.readAsBytesSync();
        final checkedOut = utf8.decode(bytes);
        expect(checkedOut.contains('\r\n'), mode == 'true');
        expect(checkedOut.replaceAll('\r\n', '\n'), fixture.canonical);
        for (final brand in ['OmoFly', '袋鼠加速']) {
          // Pass actual checkout bytes directly to production too. Fixing the
          // test input must not conceal lack of support for legitimate CRLF.
          final direct = injectAppImageBrand(checkedOut, brand);
          expect(injectAppImageBrand(direct, brand), direct);
          for (final crlf in [false, true]) {
            final input = _fixtureLineEndings(checkedOut, crlf: crlf);
            expect(input.contains('\r\n'), crlf);
            expect(input, isNot(contains('\r\r\n')));
            final result = injectAppImageBrand(input, brand);
            expect(result, direct);
            expect(injectAppImageBrand(result, brand), result);
            expect((loadYaml(result) as YamlMap)['keywords'],
                [brand, 'Clash', 'ClashMeta', 'Proxy']);
          }
        }
        expect(file.readAsBytesSync(), bytes, reason: 'Do not rewrite checkout files');
        expect(fixture.git(checkout, ['status', '--porcelain']), isEmpty);
      });
    }
    test('old double conversion reproduces #103 from an actual CRLF checkout', () {
      final checkout = fixture.checkout('true');
      final checkedOut = File(p.join(checkout.path, _appImageConfig)).readAsStringSync();
      expect(checkedOut, contains('\r\n'));
      final malformed = checkedOut.replaceAll('\n', '\r\n');
      expect(malformed, contains('\r\r\n'));
      for (final brand in ['OmoFly', '袋鼠加速']) {
        final first = injectAppImageBrand(malformed, brand);
        expect(injectAppImageBrand(first, brand), isNot(first));
        final fixed = injectAppImageBrand(_fixtureLineEndings(checkedOut, crlf: true), brand);
        expect(injectAppImageBrand(fixed, brand), fixed);
      }
    });
    test('switching brands replaces the brand slot without accumulating old names', () {
      final a = injectAppImageBrand(source, 'OmoFly');
      final b = injectAppImageBrand(a, '袋鼠加速');
      expect((loadYaml(b) as YamlMap)['keywords'], ['袋鼠加速', 'Clash', 'ClashMeta', 'Proxy']);
      expect(injectAppImageBrand(b, 'OmoFly'), a);
    });
    test('inline, empty and missing keywords are valid; non-string values fail', () {
      for (final value in ['keywords: [MyClient, Proxy]\n', 'keywords: []\n', '']) {
        final result = injectAppImageBrand('display_name: FlClash\n$value', 'Brand "quoted"');
        expect((loadYaml(result) as YamlMap)['keywords'].first, 'Brand "quoted"');
      }
      for (final value in ['keywords: 123\n', 'keywords: [123]\n']) {
        expect(() => injectAppImageBrand('display_name: FlClash\n$value', 'OmoFly'), throwsFormatException);
      }
    });
    test('blank lines and comments inside the keyword block cannot leave stale list entries', () {
      final result = injectAppImageBrand(
        'display_name: FlClash\nkeywords:\n  - MyClient\n\n  # search term\n  - Proxy\ngeneric_name: FlClash\n',
        '袋鼠加速',
      );
      expect((loadYaml(result) as YamlMap)['keywords'], ['袋鼠加速', 'Proxy']);
    });
  });

  test('flutter_launcher_icons.yaml 生成（image_path 指向品牌 png / 仅桌面）', () {
    const png = 'flavors/brand_a/assets/icons/brand_a.png';
    final out = buildLauncherIconsYaml(png);
    expect(out, contains('image_path: "$png"'));
    expect(out, contains('android: false')); // Android 走 prepare_flavor
    expect(out, contains('ios: false'));
    expect(out, contains('windows:'));
    expect(out, contains('icon_size: 256'));
    expect(out, contains('macos:'));
  });
}

void _expectRunnerBrandConfiguration(String project) {
  // Normalize only the in-memory parser input; keep checkout bytes untouched.
  final normalized = project.replaceAll('\r\n', '\n');
  final runnerConfigurations =
      RegExp(r'buildSettings = \{([\s\S]*?)\n\t\t\t\};\n\t\t\tname = (\w+);')
          .allMatches(normalized)
          .where(
            (match) =>
                match.group(1)!.contains('INFOPLIST_FILE = Runner/Info.plist;'),
          );
  expect(
    runnerConfigurations.map((match) => match.group(2)),
    unorderedEquals(['Debug', 'Release', 'Profile']),
  );
  for (final configuration in runnerConfigurations) {
    expect(
      configuration.group(1),
      contains(r'INFOPLIST_KEY_CFBundleDisplayName = "$(PRODUCT_NAME)";'),
      reason: configuration.group(2),
    );
  }
}

const _runnerProject = 'macos/Runner.xcodeproj/project.pbxproj';
const _appImageConfig = 'linux/packaging/appimage/make_config.yaml';

String _fixtureLineEndings(String source, {required bool crlf}) {
  // Source may already be CRLF after a Windows Git checkout. Canonicalize
  // before expanding LF; never manufacture CRCRLF from legitimate input.
  final lf = source.replaceAll('\r\n', '\n');
  expect(lf, isNot(contains('\r')));
  return crlf ? lf.replaceAll('\n', '\r\n') : lf;
}

class _RunnerCheckoutFixture {
  _RunnerCheckoutFixture({this.sourcePath = _runnerProject});

  final String sourcePath;
  final root = Directory.systemTemp.createTempSync('runner checkout ');
  late final seed = Directory(p.join(root.path, 'seed'));
  late final emptyConfig = p.join(root.path, 'empty-config');
  late final String canonical;
  var serial = 0;

  void initialize() {
    File(emptyConfig).writeAsStringSync('');
    Directory(p.join(root.path, 'hooks')).createSync();
    seed.createSync();
    canonical = File(
      sourcePath,
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final project = File(p.join(seed.path, sourcePath));
    project.parent.createSync(recursive: true);
    project.writeAsStringSync(canonical);
    File('.gitattributes').copySync(p.join(seed.path, '.gitattributes'));
    git(seed, ['init', '--quiet']);
    git(seed, ['config', '--local', 'user.name', 'Runner Checkout Test']);
    git(seed, [
      'config',
      '--local',
      'user.email',
      'runner-test@example.invalid',
    ]);
    git(seed, ['config', '--local', 'commit.gpgsign', 'false']);
    git(seed, ['config', '--local', 'core.autocrlf', 'false']);
    git(seed, ['config', '--local', 'core.eol', 'lf']);
    git(seed, ['add', '--', '.']);
    git(seed, ['commit', '--quiet', '-m', 'Public runner checkout fixture']);
  }

  Directory checkout(String mode) {
    final directory = Directory(p.join(root.path, 'checkout-${serial++}'));
    git(root, ['clone', '--quiet', '--no-checkout', seed.path, directory.path]);
    git(directory, ['config', '--local', 'core.autocrlf', mode]);
    git(directory, ['config', '--local', 'core.eol', 'lf']);
    git(directory, ['checkout', '--quiet', '--detach', 'HEAD']);
    return directory;
  }

  String git(Directory directory, List<String> args) {
    final result = Process.runSync(
      'git',
      [
        '-c',
        'core.attributesFile=$emptyConfig',
        '-c',
        'core.hooksPath=${p.join(root.path, 'hooks')}',
        ...args,
      ],
      workingDirectory: directory.path,
      environment: {
        for (final entry in Platform.environment.entries)
          if (!entry.key.toUpperCase().startsWith('GIT_'))
            entry.key: entry.value,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': emptyConfig,
        'GIT_ATTR_NOSYSTEM': '1',
        'GIT_TERMINAL_PROMPT': '0',
      },
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(
      result.exitCode,
      0,
      reason: 'git ${args.join(' ')}: ${result.stderr}',
    );
    return result.stdout as String;
  }
}
