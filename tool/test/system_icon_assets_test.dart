// Offline resource and build-injection contracts. No browser or native build.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_launcher_icons/utils.dart' as image_utils;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../system_icon_assets.dart';

const _icoSizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
const _badgeColors = [0xe5a14b, 0x12b8a6, 0x4b8fe8];
const _androidSizes = {
  'drawable': 24,
  'drawable-hdpi': 36,
  'drawable-xhdpi': 48,
  'drawable-xxhdpi': 72,
  'drawable-xxxhdpi': 96,
};
final _projectRoot = Directory.current.path;

void main() {
  group('committed system icons', () {
    for (final brand in ['brand_a', 'brand_b']) {
      test(
        '$brand loads the complete platform-specific resource set',
        () async {
          final assets = await loadSystemIconAssets(
            projectRoot: _projectRoot,
            flavor: brand,
          );
          expect(assets.flavor, brand);
          expect(
            assets.files.keys,
            unorderedEquals([
              for (var state = 1; state <= 3; state++) ...[
                'windows/status_$state.ico',
                'linux/status_$state.png',
              ],
              'macos/status_1.png',
              for (final density in _androidSizes.keys)
                'android/$density/xb_brand_system_icon.png',
            ]),
          );
          expect(assets.manifest['brand'], brand);
        },
      );

      test('$brand Windows ICOs contain all native-size PNG frames', () async {
        final temp = Directory.systemTemp.createTempSync('system_icon_frames_');
        addTearDown(() => temp.deleteSync(recursive: true));
        for (var state = 1; state <= 3; state++) {
          final bytes = _sourceIcon(
            brand,
            'windows/status_$state.ico',
          ).readAsBytesSync();
          final data = ByteData.sublistView(bytes);
          expect(data.getUint16(0, Endian.little), 0);
          expect(data.getUint16(2, Endian.little), 1);
          expect(data.getUint16(4, Endian.little), _icoSizes.length);
          var expectedOffset = 6 + 16 * _icoSizes.length;
          for (var frame = 0; frame < _icoSizes.length; frame++) {
            final entry = 6 + frame * 16;
            final size = _icoSizes[frame];
            expect(bytes[entry] == 0 ? 256 : bytes[entry], size);
            expect(bytes[entry + 1] == 0 ? 256 : bytes[entry + 1], size);
            expect(data.getUint16(entry + 4, Endian.little), 1);
            expect(data.getUint16(entry + 6, Endian.little), 32);
            final length = data.getUint32(entry + 8, Endian.little);
            final offset = data.getUint32(entry + 12, Endian.little);
            expect(offset, expectedOffset, reason: 'Frames must not overlap');
            expect(offset + length, lessThanOrEqualTo(bytes.length));
            final png = File(p.join(temp.path, 'frame.png'))
              ..writeAsBytesSync(bytes.sublist(offset, offset + length));
            final image = (await image_utils.decodeImageFile(png.path))!;
            expect([image.width, image.height], [size, size]);
            final badge = image.getPixel(
              (size * .85).floor(),
              (size * .85).floor(),
            );
            expect(_rgb(badge.r, badge.g, badge.b), _badgeColors[state - 1]);
            expect(badge.a, 255);
            expectedOffset += length;
          }
          expect(
            expectedOffset,
            bytes.length,
            reason: 'No trailing ICO payload',
          );
        }
      });

      test('$brand Linux badges use the three agreed colors', () async {
        for (var state = 1; state <= 3; state++) {
          final image = (await image_utils.decodeImageFile(
            _sourceIcon(brand, 'linux/status_$state.png').path,
          ))!;
          expect([image.width, image.height], [108, 108]);
          final badge = image.getPixel(92, 92);
          expect(_rgb(badge.r, badge.g, badge.b), _badgeColors[state - 1]);
          expect(badge.a, 255);
          expect(image.getPixel(107, 0).a, 0);
        }
      });

      test(
        '$brand macOS and Android are transparent monochrome masks',
        () async {
          final paths = {
            'macos/status_1.png': (128, 0),
            for (final entry in _androidSizes.entries)
              'android/${entry.key}/xb_brand_system_icon.png': (
                entry.value,
                255,
              ),
          };
          for (final entry in paths.entries) {
            final image = (await image_utils.decodeImageFile(
              _sourceIcon(brand, entry.key).path,
            ))!;
            expect(
              [image.width, image.height],
              [entry.value.$1, entry.value.$1],
            );
            var transparent = 0;
            var visible = 0;
            var wrongColor = 0;
            for (final pixel in image) {
              if (pixel.a == 0) {
                transparent++;
              } else {
                visible++;
                if (pixel.r != entry.value.$2 ||
                    pixel.g != entry.value.$2 ||
                    pixel.b != entry.value.$2) {
                  wrongColor++;
                }
              }
            }
            expect(transparent, greaterThan(0), reason: entry.key);
            expect(visible, greaterThan(0), reason: entry.key);
            expect(wrongColor, 0, reason: entry.key);
          }
        },
      );
    }
  });

  group('resource validation rejects stale or malformed inputs', () {
    late Directory fixture;
    late File manifestFile;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('system_icon_validation_');
      _copyBrandFixture(fixture, 'brand_a');
      manifestFile = File(
        p.join(
          fixture.path,
          'flavors',
          'brand_a',
          'system_icons',
          'manifest.json',
        ),
      );
    });
    tearDown(() => fixture.deleteSync(recursive: true));

    Future<SystemIconAssets> load() =>
        loadSystemIconAssets(projectRoot: fixture.path, flavor: 'brand_a');

    void changeManifest(void Function(Map<String, dynamic>) change) {
      final manifest =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      change(manifest);
      manifestFile.writeAsStringSync(jsonEncode(manifest));
    }

    test('fixture is complete without private flavor configuration', () async {
      expect((await load()).files, hasLength(12));
      expect(
        File(p.join(fixture.path, 'flavors/brand_a/flavor.yaml')).existsSync(),
        isFalse,
      );
    });

    for (final field in [
      'schema',
      'brand',
      'badge_colors',
      'source',
      'files',
    ]) {
      test('rejects missing manifest $field', () async {
        changeManifest((manifest) => manifest.remove(field));
        await expectLater(load(), throwsFormatException);
      });
    }

    test('rejects a manifest belonging to another brand', () async {
      changeManifest((manifest) => manifest['brand'] = 'brand_b');
      await expectLater(load(), throwsFormatException);
    });

    test('rejects an unsupported schema and changed status color', () async {
      final original = manifestFile.readAsStringSync();
      changeManifest((manifest) => manifest['schema'] = 2);
      await expectLater(load(), throwsFormatException);
      manifestFile.writeAsStringSync(original);
      changeManifest((manifest) {
        (manifest['badge_colors'] as Map)['status_2'] = '#FFFFFF';
      });
      await expectLater(load(), throwsFormatException);
    });

    test('rejects missing, additional, or traversing manifest files', () async {
      final original = manifestFile.readAsStringSync();
      for (final badKey in [null, 'linux/extra.png', '../outside.png']) {
        manifestFile.writeAsStringSync(original);
        changeManifest((manifest) {
          final files = manifest['files'] as Map<String, dynamic>;
          final metadata = files['linux/status_1.png'];
          if (badKey == null) {
            files.remove('linux/status_1.png');
          } else {
            files[badKey] = metadata;
          }
        });
        await expectLater(load(), throwsFormatException);
      }
    });

    test('rejects a missing resource and changed resource bytes', () async {
      final file = File(
        p.join(fixture.path, 'flavors/brand_a/system_icons/linux/status_1.png'),
      );
      final original = file.readAsBytesSync();
      file.deleteSync();
      await expectLater(load(), throwsFormatException);
      original[original.length - 1] ^= 1;
      file.writeAsBytesSync(original);
      await expectLater(load(), throwsFormatException);
    });

    for (final source in [
      'assets/icons/brand_a.png',
      'system_icons/monochrome.svg',
    ]) {
      test('rejects stale source fingerprint: $source', () async {
        File(
          p.join(fixture.path, 'flavors/brand_a', source),
        ).writeAsStringSync('changed source');
        await expectLater(load(), throwsFormatException);
      });
    }

    test(
      'rejects PNG dimensions even with a matching content fingerprint',
      () async {
        const key = 'linux/status_1.png';
        final file = File(
          p.join(fixture.path, 'flavors/brand_a/system_icons', key),
        );
        final bytes = file.readAsBytesSync();
        ByteData.sublistView(bytes).setUint32(16, 999, Endian.big);
        file.writeAsBytesSync(bytes);
        changeManifest((manifest) {
          final metadata = (manifest['files'] as Map)[key] as Map;
          metadata['sha256'] = sha256.convert(bytes).toString();
        });
        await expectLater(load(), throwsFormatException);
      },
    );

    test(
      'rejects an out-of-bounds ICO frame with a matching fingerprint',
      () async {
        const key = 'windows/status_1.ico';
        final file = File(
          p.join(fixture.path, 'flavors/brand_a/system_icons', key),
        );
        final bytes = file.readAsBytesSync();
        ByteData.sublistView(bytes).setUint32(18, bytes.length, Endian.little);
        file.writeAsBytesSync(bytes);
        changeManifest((manifest) {
          final metadata = (manifest['files'] as Map)[key] as Map;
          metadata['sha256'] = sha256.convert(bytes).toString();
        });
        await expectLater(load(), throwsFormatException);
      },
    );
  });

  group('build-time destination writes', () {
    late Directory target;
    late SystemIconAssets brandA;

    setUp(() async {
      target = Directory.systemTemp.createTempSync('system_icon_writes_');
      brandA = await loadSystemIconAssets(
        projectRoot: _projectRoot,
        flavor: 'brand_a',
      );
    });
    tearDown(() => target.deleteSync(recursive: true));

    test('platform mappings cover v0.9.2 monochrome and color tray states', () {
      for (final platform in ['windows', 'linux', 'macos']) {
        final writes = desktopSystemIconWrites(brandA, platform: platform);
        final extension = platform == 'windows' ? 'ico' : 'png';
        final directory = platform == 'linux' ? 'unix' : platform;
        final states = platform == 'macos' ? [1, 4] : [1, 2, 3, 4];
        final scales = platform == 'windows'
            ? ['']
            : ['', '2.0x/', '3.0x/', '4.0x/'];
        expect(
          writes.keys,
          unorderedEquals([
            if (platform == 'macos')
              for (final state in [1, 2, 3, 4])
                for (final scale in ['', '2.0x/', '3.0x/', '4.0x/'])
                  'assets/images/tray/unix/${scale}status_$state.png',
            for (final state in states)
              for (final scale in scales)
                'assets/images/tray/$directory/${scale}status_$state.$extension',
          ]),
        );
        for (final state in states) {
          for (final scale in scales) {
            expect(
              writes['assets/images/tray/$directory/${scale}status_$state.$extension'],
              orderedEquals(
                brandA
                    .files['$platform/status_${state == 4 ? 1 : state}.$extension']!,
              ),
            );
          }
        }
      }
      expect(
        () => desktopSystemIconWrites(brandA, platform: 'android'),
        throwsFormatException,
      );
    });

    test('dry run creates no directories or files', () {
      applySystemIconWrites(
        projectRoot: target.path,
        writes: desktopSystemIconWrites(brandA, platform: 'linux'),
        dryRun: true,
      );
      expect(target.listSync(), isEmpty);
    });

    test(
      'writes exact committed bytes and leaves identical files untouched',
      () {
        final writes = desktopSystemIconWrites(brandA, platform: 'windows');
        applySystemIconWrites(projectRoot: target.path, writes: writes);
        final unchangedTime = DateTime.utc(2000, 1, 1);
        for (final entry in writes.entries) {
          final file = File(p.join(target.path, entry.key));
          expect(file.readAsBytesSync(), orderedEquals(entry.value));
          file.setLastModifiedSync(unchangedTime);
        }
        applySystemIconWrites(projectRoot: target.path, writes: writes);
        for (final key in writes.keys) {
          expect(
            File(p.join(target.path, key)).lastModifiedSync().toUtc(),
            unchangedTime,
          );
        }
      },
    );

    test(
      'switching brands replaces stale tray icons without changing app icon',
      () async {
        final appIcon = File(p.join(target.path, 'assets/images/icon.png'));
        appIcon.parent.createSync(recursive: true);
        appIcon.writeAsStringSync('launcher icon sentinel');
        applySystemIconWrites(
          projectRoot: target.path,
          writes: desktopSystemIconWrites(brandA, platform: 'linux'),
        );
        final brandB = await loadSystemIconAssets(
          projectRoot: _projectRoot,
          flavor: 'brand_b',
        );
        final writes = desktopSystemIconWrites(brandB, platform: 'linux');
        applySystemIconWrites(projectRoot: target.path, writes: writes);
        for (final entry in writes.entries) {
          expect(
            File(p.join(target.path, entry.key)).readAsBytesSync(),
            orderedEquals(entry.value),
          );
        }
        expect(appIcon.readAsStringSync(), 'launcher icon sentinel');
      },
    );

    test('preflights every destination before changing any valid target', () {
      const validPath = 'assets/images/tray/unix/status_1.png';
      final valid = File(p.join(target.path, validPath));
      valid.parent.createSync(recursive: true);
      valid.writeAsStringSync('original');
      for (final badPath in [
        '../escaped.png',
        p.join(target.parent.path, 'escaped.png'),
      ]) {
        expect(
          () => applySystemIconWrites(
            projectRoot: target.path,
            writes: {
              validPath: Uint8List.fromList([1, 2]),
              badPath: Uint8List.fromList([3, 4]),
            },
          ),
          throwsFormatException,
        );
        expect(valid.readAsStringSync(), 'original');
      }
    });

    for (final linkParent in [false, true]) {
      test(
        'rejects symlink ${linkParent ? 'parent directories' : 'destinations'}',
        () {
          final outside = Directory.systemTemp.createTempSync(
            'system_icon_outside_',
          );
          addTearDown(() => outside.deleteSync(recursive: true));
          final externalFile = File(p.join(outside.path, 'status_2.png'))
            ..writeAsStringSync('outside');
          final iconDir = Directory(
            p.join(target.path, 'assets/images/tray/unix'),
          );
          iconDir.parent.createSync(recursive: true);
          final first = File(p.join(iconDir.path, 'status_1.png'));
          if (linkParent) {
            Link(iconDir.path).createSync(outside.path);
          } else {
            iconDir.createSync();
            first.writeAsStringSync('original');
            Link(
              p.join(iconDir.path, 'status_2.png'),
            ).createSync(externalFile.path);
          }
          expect(
            () => applySystemIconWrites(
              projectRoot: target.path,
              writes: {
                'assets/images/tray/unix/status_1.png': Uint8List.fromList([1]),
                'assets/images/tray/unix/status_2.png': Uint8List.fromList([2]),
              },
            ),
            throwsFormatException,
          );
          if (linkParent) {
            expect(first.existsSync(), isFalse);
          } else {
            expect(first.readAsStringSync(), 'original');
          }
          expect(externalFile.readAsStringSync(), 'outside');
        },
        skip: Platform.isWindows
            ? 'Windows symlink creation needs privileges'
            : false,
      );
    }
  });
}

int _rgb(num red, num green, num blue) =>
    (red.toInt() << 16) | (green.toInt() << 8) | blue.toInt();

File _sourceIcon(String brand, String relativePath) =>
    File(p.join(_projectRoot, 'flavors', brand, 'system_icons', relativePath));

void _copyBrandFixture(Directory target, String brand) {
  final source = Directory(
    p.join(_projectRoot, 'flavors', brand, 'system_icons'),
  );
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    if (entity is File) {
      final file = File(
        p.join(
          target.path,
          'flavors',
          brand,
          'system_icons',
          p.relative(entity.path, from: source.path),
        ),
      );
      file.parent.createSync(recursive: true);
      entity.copySync(file.path);
    }
  }
  final colorPath = p.join('flavors', brand, 'assets', 'icons', '$brand.png');
  final color = File(p.join(target.path, colorPath));
  color.parent.createSync(recursive: true);
  File(p.join(_projectRoot, colorPath)).copySync(color.path);
}
