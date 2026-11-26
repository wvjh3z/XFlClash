import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../prepare_release_context.dart';

Map<String, Object> make({
  String platform = 'windows',
  String arch = 'amd64',
  String number = '30',
  Map? flavor,
  bool zip = false,
  bool rpm = true,
}) => releaseContext(
  flavor:
      flavor ??
      {
        'appName': '袋鼠加速',
        'versionName': '0.0.1',
        'updatePackageName': 'ds',
        'aesKey': 'PRIVATE_MARKER',
      },
  pubspec: {'version': '0.8.93+2026052901'},
  flavorId: 'brand_b',
  platform: platform,
  arch: arch,
  buildNumber: number,
  sourceRevision: 'a' * 40,
  buildTag: '202610182200',
  includeZip: zip,
  includeRpm: rpm,
);

String get _dart {
  final flutter = Platform.environment['FLUTTER_ROOT'];
  return Platform.isWindows && flutter != null
      ? '$flutter/bin/cache/dart-sdk/bin/dart.exe' : 'dart';
}

Future<ProcessResult> _runDart(List<String> args, Directory directory,
    String stage, {Duration budget = const Duration(seconds: 60)}) async {
  final elapsed = Stopwatch()..start();
  final process = await Process.start(_dart, args, workingDirectory: directory.path,
    environment: Map.of(Platform.environment)..remove('GITHUB_ENV'),
    includeParentEnvironment: false);
  final output = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final errors = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  final exit = process.exitCode;
  try {
    final code = await exit.timeout(budget);
    return ProcessResult(process.pid, code, await output, await errors);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await exit.timeout(const Duration(seconds: 10));
    await Future.wait([output, errors]);
    throw TimeoutException('Release context CLI timed out: $stage (pid ${process.pid})', budget);
  } finally {
    stdout.writeln('Release context CLI: $stage took ${elapsed.elapsedMilliseconds} ms');
  }
}

void main() {
  test(
    'public context separates base/product/version and never exports secrets',
    () {
      final c = make();
      expect(c['base_version'], '0.8.93');
      expect(c['product_version'], '0.0.1');
      expect(c['build_number'], 30);
      expect(c['package_app_name'], 'ds');
      expect(c['package_prefix'], 'ds');
      expect(jsonEncode(c), isNot(contains('PRIVATE_MARKER')));
      expect(c.length, 12);
    },
  );
  test('all platform target sets and optional local formats', () {
    expect(make(platform: 'android', arch: '')['targets'], ['apk']);
    expect(make(platform: 'linux', arch: 'amd64')['targets'], [
      'deb',
      'appimage',
      'rpm',
    ]);
    expect(make(platform: 'linux', arch: 'arm64')['targets'], [
      'deb',
      'appimage',
    ]);
    expect(make(platform: 'linux', rpm: false)['targets'], ['deb', 'appimage']);
    expect(make(platform: 'macos', arch: 'arm64')['targets'], ['dmg']);
    expect(make(zip: true)['targets'], ['exe', 'zip']);
    expect(make(arch: 'arm64')['targets'], ['exe']);
    expect(make(arch: 'arm64', zip: true)['targets'], ['exe', 'zip']);
  });
  test('invalid identity and unsupported targets fail before use', () {
    for (final n in ['', '0', '01', '65536', '30\n']) {
      expect(() => make(number: n), throwsFormatException);
    }
    expect(() => make(arch: 'x86'), throwsFormatException);
    expect(
      () => make(platform: 'android', arch: 'amd64'),
      throwsFormatException,
    );
    expect(() => make(platform: 'macos', zip: true), throwsFormatException);
    expect(
      () => make(
        flavor: {
          'appName': 'A',
          'versionName': '0.1.0',
          'updatePackageName': '../escape',
        },
      ),
      throwsFormatException,
    );
  });
  test('stalled CLI is reaped before fixture cleanup', () async {
    final temp = Directory.systemTemp.createTempSync('context timeout ');
    addTearDown(() { if (temp.existsSync()) temp.deleteSync(recursive: true); });
    final script = File('${temp.path}/wait.dart')
      ..writeAsStringSync("import 'dart:io'; void main() { sleep(const Duration(minutes: 2)); }");
    await expectLater(_runDart([script.path], temp, 'timeout fixture',
        budget: const Duration(seconds: 2)), throwsA(isA<TimeoutException>().having(
        (e) => e.message, 'stage', contains('timeout fixture'))));
    temp.deleteSync(recursive: true);
  });
  test(
    'real CLI parses YAML quotes/comments and preserves source counter',
    () async {
      final root = Directory.current.path;
      final temp = Directory.systemTemp.createTempSync('context fixture ');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/flavors/brand_b/flavor.yaml')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          "appName: '袋鼠加速'\nversionName: '1.2.3+test' # comment\nupdatePackageName: ds\naesKey: PRIVATE_MARKER\n",
        );
      File(
        '${temp.path}/pubspec.yaml',
      ).writeAsStringSync("name: fixture\nversion: '0.8.93+2026052901'\n");
      File(
        '${temp.path}/distribute_options.yaml',
      ).writeAsStringSync('app_name: old\n');
      final counter = File('${temp.path}/scripts/build_number.brand_b.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('50\n');
      Future<ProcessResult> run(String target, String number, String stage) =>
          _runDart([
            '--packages=$root/.dart_tool/package_config.json',
            '$root/tool/prepare_release_context.dart',
            '--flavor', 'brand_b', '--platform', target,
            '--arch', target == 'android' ? '' : 'amd64',
            '--build-number', number, '--source-revision', 'a' * 40,
            '--build-tag', '202610182200', '--align-package-name',
          ], temp, stage);
      final result = await run('windows', '30', 'windows');
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
      final c =
          jsonDecode(
                File(
                  '${temp.path}/build/release-context.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(c['product_version'], '1.2.3+test');
      expect(c['build_number'], 30);
      // Same formal CLI: Linux product/build metadata, then no leakage to Android.
      for (final (i, target) in ['linux', 'linux', 'android'].indexed) {
        final again = await run(target, '31', '$target #${i + 1}');
        expect(again.exitCode, 0, reason: '${again.stdout} ${again.stderr}');
        final options = File(
          '${temp.path}/distribute_options.yaml',
        ).readAsStringSync();
        expect(
          options,
          target == 'linux'
              ? 'app_name: "daishu"\nlinux_package_version: "1.2.3+31"\n'
              : 'app_name: "ds"\n',
        );
      }
      expect(counter.readAsStringSync(), '50\n');
      expect(
        File('${temp.path}/distribute_options.yaml').readAsStringSync(),
        'app_name: "ds"\n',
      );
      expect(
        '${result.stdout}${result.stderr}${jsonEncode(c)}',
        isNot(contains('PRIVATE_MARKER')),
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
