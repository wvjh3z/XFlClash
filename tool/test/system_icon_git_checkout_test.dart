// Real Git checkouts protect manifest fingerprints from platform EOL filters.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../system_icon_assets.dart';

const _brands = ['brand_a', 'brand_b'];
final _repository = Directory.current.path;

void main() {
  late _GitFixture fixture;

  setUpAll(() {
    fixture = _GitFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    fixture.initialize();
  });

  group('system icons survive real Git checkout', () {
    for (final autocrlf in ['false', 'input', 'true']) {
      test('core.autocrlf=$autocrlf preserves both brands', () async {
        final checkout = fixture.checkout(autocrlf);
        for (final entry in fixture.committed.entries) {
          expect(
            File(p.join(checkout.path, entry.key)).readAsBytesSync(),
            orderedEquals(entry.value),
            reason: '$autocrlf: ${entry.key}',
          );
          // Check every tracked input, including manifests and color sources.
          expect(
            fixture.git(checkout, [
              'check-attr',
              '-z',
              'text',
              '--',
              entry.key,
            ]),
            '${entry.key}\u0000text\u0000unset\u0000',
          );
        }
        for (final brand in _brands) {
          final assets = await loadSystemIconAssets(
            projectRoot: checkout.path,
            flavor: brand,
          );
          expect(assets.flavor, brand);
          expect(assets.files, hasLength(12));
          for (final entry in assets.files.entries) {
            expect(
              entry.value,
              orderedEquals(
                fixture.committed['flavors/$brand/system_icons/${entry.key}']!,
              ),
            );
          }
          expect(
            File(
              p.join(checkout.path, 'flavors/$brand/flavor.yaml'),
            ).existsSync(),
            isFalse,
          );
        }
      });
    }

    test(
      'without attributes autocrlf=true reproduces only B source failure',
      () async {
        final checkout = fixture.checkout('true', protected: false);
        const sourceA = 'flavors/brand_a/system_icons/monochrome.svg';
        const sourceB = 'flavors/brand_b/system_icons/monochrome.svg';
        final originalA = fixture.committed[sourceA]!;
        final originalB = fixture.committed[sourceB]!;
        expect(originalA.where((byte) => byte == 10), isEmpty);
        expect(originalB.where((byte) => byte == 10), hasLength(1));
        expect(originalB.where((byte) => byte == 13), isEmpty);
        expect(
          File(p.join(checkout.path, sourceA)).readAsBytesSync(),
          orderedEquals(originalA),
        );
        final converted = File(
          p.join(checkout.path, sourceB),
        ).readAsBytesSync();
        expect(
          converted,
          orderedEquals([
            for (final byte in originalB) ...[if (byte == 10) 13, byte],
          ]),
        );
        expect(converted, hasLength(originalB.length + 1));
        final before = _snapshot(checkout);
        expect(
          (await loadSystemIconAssets(
            projectRoot: checkout.path,
            flavor: 'brand_a',
          )).files,
          hasLength(12),
        );
        await expectLater(
          loadSystemIconAssets(projectRoot: checkout.path, flavor: 'brand_b'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Brand icon source changed; regenerate system icons',
            ),
          ),
        );
        expect(
          _snapshot(checkout),
          before,
          reason: 'Validation must not repair',
        );
      },
    );

    for (final brand in _brands) {
      for (final relative in ['monochrome.svg', 'windows/status_1.ico']) {
        test(
          '$brand still rejects tampered $relative without rewriting',
          () async {
            final checkout = fixture.checkout('true');
            await loadSystemIconAssets(
              projectRoot: checkout.path,
              flavor: brand,
            );
            final target = File(
              p.join(checkout.path, 'flavors/$brand/system_icons', relative),
            );
            final tampered = target.readAsBytesSync();
            tampered[tampered.length - 1] ^= 1;
            target.writeAsBytesSync(tampered);
            final before = _snapshot(checkout);
            await expectLater(
              loadSystemIconAssets(projectRoot: checkout.path, flavor: brand),
              throwsA(
                isA<FormatException>().having(
                  (error) => error.message,
                  'message',
                  relative.endsWith('.svg')
                      ? 'Brand icon source changed; regenerate system icons'
                      : 'System icon asset integrity check failed',
                ),
              ),
            );
            expect(_snapshot(checkout), before);
            expect(target.readAsBytesSync(), orderedEquals(tampered));
          },
        );
      }
    }
  });
}

class _GitFixture {
  final root = Directory.systemTemp.createTempSync('system_icon_git_checkout_');
  final committed = <String, Uint8List>{};
  late final Directory seed = Directory(p.join(root.path, 'seed'));
  late final String emptyConfig = p.join(root.path, 'empty-config');
  late String protectedCommit;
  late String unprotectedCommit;
  var checkoutSerial = 0;

  void initialize() {
    File(emptyConfig).writeAsStringSync('');
    Directory(p.join(root.path, 'hooks')).createSync();
    // Read only committed public assets, never local private flavor inputs.
    final paths = git(Directory(_repository), [
      'ls-tree',
      '-r',
      '-z',
      '--name-only',
      'HEAD',
      '--',
      for (final brand in _brands) ...[
        'flavors/$brand/system_icons',
        'flavors/$brand/assets/icons/$brand.png',
      ],
    ]).split('\u0000').where((path) => path.isNotEmpty);
    for (final path in paths) {
      committed[path] = Uint8List.fromList(
        _git(Directory(_repository), [
              'show',
              'HEAD:$path',
            ], binary: true).stdout
            as List<int>,
      );
    }
    expect(committed, hasLength(30));
    seed.createSync();
    for (final entry in committed.entries) {
      final file = File(p.join(seed.path, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(entry.value);
    }
    // Use the actual policy under test, including uncommitted policy changes.
    File(
      p.join(_repository, '.gitattributes'),
    ).copySync(p.join(seed.path, '.gitattributes'));
    git(seed, ['init', '--quiet']);
    git(seed, ['config', '--local', 'user.name', 'System Icon Checkout Test']);
    git(seed, ['config', '--local', 'user.email', 'icon-test@example.invalid']);
    git(seed, ['config', '--local', 'commit.gpgsign', 'false']);
    git(seed, ['config', '--local', 'core.autocrlf', 'false']);
    git(seed, ['add', '--', '.']);
    git(seed, ['commit', '--quiet', '-m', 'Public icon checkout fixture']);
    protectedCommit = git(seed, ['rev-parse', 'HEAD']).trim();
    git(seed, ['rm', '--quiet', '--', '.gitattributes']);
    git(seed, [
      'commit',
      '--quiet',
      '-m',
      'Negative control without attributes',
    ]);
    unprotectedCommit = git(seed, ['rev-parse', 'HEAD']).trim();
  }

  Directory checkout(String autocrlf, {bool protected = true}) {
    final target = Directory(p.join(root.path, 'checkout-${checkoutSerial++}'));
    // Configure EOL conversion before checkout so Git performs real filtering.
    git(root, ['clone', '--quiet', '--no-checkout', seed.path, target.path]);
    git(target, ['config', '--local', 'core.autocrlf', autocrlf]);
    git(target, ['config', '--local', 'core.eol', 'crlf']);
    git(target, [
      'checkout',
      '--quiet',
      '--detach',
      protected ? protectedCommit : unprotectedCommit,
    ]);
    return target;
  }

  String git(Directory directory, List<String> arguments) =>
      _git(directory, arguments).stdout as String;

  ProcessResult _git(
    Directory directory,
    List<String> arguments, {
    bool binary = false,
  }) {
    final result = Process.runSync(
      'git',
      [
        '-c',
        'core.attributesFile=$emptyConfig',
        '-c',
        'core.hooksPath=${p.join(root.path, 'hooks')}',
        ...arguments,
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
      stdoutEncoding: binary ? null : utf8,
      stderrEncoding: utf8,
    );
    expect(
      result.exitCode,
      0,
      reason: 'git ${arguments.join(' ')}: ${result.stderr}',
    );
    return result;
  }
}

Map<String, String> _snapshot(Directory checkout) {
  final files = <String, String>{};
  void visit(Directory directory) {
    for (final entity in directory.listSync(followLinks: false)) {
      if (p.basename(entity.path) == '.git') continue;
      if (entity is Directory) {
        visit(entity);
      } else if (entity is File) {
        files[p.relative(entity.path, from: checkout.path)] = sha256
            .convert(entity.readAsBytesSync())
            .toString();
      }
    }
  }

  visit(checkout);
  return files;
}
