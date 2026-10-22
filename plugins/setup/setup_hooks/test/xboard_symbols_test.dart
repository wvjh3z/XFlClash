import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:setup_hooks/src/build.dart';
import 'package:setup_hooks/src/target.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real Go/runtime hash, helper binding, companion cache and policy invalidation',
    () async {
      final root = Directory.systemTemp.createTempSync('core-symbols-中文-');
      addTearDown(() => root.deleteSync(recursive: true));
      void write(String name, String body) {
        final file = File('${root.path}/$name');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(body);
      }

      write('tool/native_toolchain.json', '{"rust":"1.99.0"}');
      write('core/go.mod', 'module fixture\ngo 1.24\n');
      write(
        'core/cmd/core/main.go',
        'package main\nfunc main() { println("symbol fixture") }\n',
      );
      write('build_config.yaml', 'tags: ""\ngo_ldflags: "-s -w"\n');
      write(
        'services/helper/Cargo.toml',
        '[package]\nname="helper"\nversion="0.0.1"\nedition="2021"\n',
      );
      write(
        'services/helper/src/main.rs',
        'fn main() { println!("{}", env!("CORE_SHA256")); }\n',
      );
      final harness = Directory('${root.path}/harness')..createSync();
      write('harness/pubspec.yaml', 'name: fixture\n');
      write('harness/lib/policy.dart', '// first policy\n');
      expect(
        Process.runSync('cargo', [
          'generate-lockfile',
          '--offline',
        ], workingDirectory: '${root.path}/services/helper').exitCode,
        0,
      );
      write('.gitignore', '.dart_tool/\nlibclash/\n**/target/\n');
      for (final args in [
        ['init', '--quiet', '--template='],
        ['add', '.'],
        [
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          '-c',
          'commit.gpgSign=false',
          'commit',
          '--quiet',
          '-m',
          'fixture',
        ],
      ]) {
        expect(
          Process.runSync('git', args, workingDirectory: root.path).exitCode,
          0,
        );
      }
      final target = Platform.version.contains('arm64')
          ? Target.linuxArm64
          : Target.linuxAmd64;
      final request = BuildRequest(
        rootDir: root.path,
        target: target,
        harnessDir: harness.path,
      );
      final first = await buildPlatform(request);
      expect(first.rebuilt, true);
      final runtime = File('${root.path}/libclash/linux/FlClashCore');
      final full = File('${runtime.path}.unstripped');
      expect(full.lengthSync(), greaterThan(runtime.lengthSync()));
      final identity = sha256.convert(runtime.readAsBytesSync()).toString();
      final helper = Process.runSync(
        '${root.path}/libclash/linux/FlClashHelperService',
        [],
      );
      expect(helper.exitCode, 0);
      expect((helper.stdout as String).trim(), identity);
      final manifest = File(
        '${root.path}/libclash/linux/manifest.json',
      ).readAsStringSync();
      expect(manifest, contains(identity));
      final again = await buildPlatform(request);
      expect(again.rebuilt, false);
      full.deleteSync();
      final missing = await buildPlatform(request);
      expect(missing.rebuilt, true);
      expect(full.existsSync(), true);
      write('harness/lib/policy.dart', '// modified symbol policy\n');
      final changed = await buildPlatform(request);
      expect(changed.rebuilt, true);
      final sections = Process.runSync('readelf', ['-S', '--wide', full.path]);
      final cli = Platform.environment['SENTRY_CLI'] ?? 'sentry-cli';
      final symbols = Process.runSync(cli, [
        'debug-files',
        'check',
        '--json',
        full.path,
      ]);
      expect(symbols.exitCode, 0, reason: '${symbols.stderr}');
      expect((jsonDecode(symbols.stdout as String) as Map)['is_usable'], true);
      expect(sections.stdout, contains('.debug_info'));
      expect(sections.stdout, contains('.debug_line'));
      expect(jsonDecode(manifest), isA<Map>());
    },
    skip: !Platform.isLinux,
    timeout: Timeout(Duration(minutes: 3)),
  );
}
