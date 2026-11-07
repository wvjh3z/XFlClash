import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/xb_profile_file_write.dart';
import 'package:fl_clash/xboard/services/profile_recovery_owner.dart';

void main() {
  test(
    'diagnostic categories are bounded and reporting failure is nonfatal',
    () {
      var calls = 0;
      final diagnostics = ProfileRecoveryDiagnostics((_) {
        calls++;
        throw StateError('reporter offline');
      });
      for (var i = 0; i < 100; i++) {
        for (final warning in ProfileRecoveryWarning.values) {
          diagnostics.report(warning);
        }
      }
      expect(calls, ProfileRecoveryWarning.values.length);
    },
  );
  for (final brand in ['brand_a', 'brand_b']) {
    test(
      '$brand recovery cleanup respects owner profile and legacy boundaries',
      () async {
        final root = await Directory.systemTemp.createTemp('xb-owned-');
        final target = File('${root.path}/42.yaml');
        final owner = ProfileRecoveryOwner(brand, 'a');
        Future<XbProfileFileWrite> create(
          ProfileRecoveryOwner? who, {
          String? path,
        }) => XbProfileFileWrite.create(
          targetPath: path ?? target.path,
          bytes: Uint8List.fromList([1]),
          ensureCurrent: () {},
          recoveryOwner: who,
        );
        try {
          final own = await create(owner);
          final other = await create(ProfileRecoveryOwner(brand, 'b'));
          final otherBrand = await create(
            ProfileRecoveryOwner(
              brand == 'brand_a' ? 'brand_b' : 'brand_a',
              'a',
            ),
          );
          final otherId = await create(owner, path: '${root.path}/43.yaml');
          final legacy = await create(null);
          await XbProfileFileWrite.cleanupOwned(
            targetPath: target.path,
            owner: owner,
          );
          expect(await own.directory.exists(), isFalse);
          for (final op in [other, otherBrand, otherId, legacy]) {
            expect(await op.directory.exists(), isTrue);
          }
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
    test(
      '$brand retained rollback backup is cleaned by later owner operation',
      () async {
        final root = await Directory.systemTemp.createTemp('xb-owned-');
        final target = File('${root.path}/42.yaml');
        final owner = ProfileRecoveryOwner(brand, 'a');
        try {
          await target.writeAsString('old');
          var calls = 0;
          final op = await XbProfileFileWrite.create(
            targetPath: target.path,
            bytes: Uint8List.fromList('new'.codeUnits),
            ensureCurrent: () {},
            recoveryOwner: owner,
            rename: (f, p) async {
              if (++calls == 2) {
                throw FileSystemException('rollback blocked', p);
              }
              return f.rename(p);
            },
          );
          await op.publish();
          await expectLater(op.rollback(), throwsA(isA<FileSystemException>()));
          await op.cleanup();
          expect(await op.backup.readAsString(), 'old');
          await XbProfileFileWrite.cleanupOwned(
            targetPath: target.path,
            owner: owner,
          );
          expect(await op.directory.exists(), isFalse);
          expect(await target.readAsString(), 'new');
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
    for (final failAt in [
      'candidate.yaml',
      'previous.yaml',
      'owner.pending',
      'owner.json',
      'directory',
    ]) {
      test(
        '$brand in-flight cleanup fails at $failAt without losing plaintext ownership',
        () async {
          final root = await Directory.systemTemp.createTemp('xb-clean-order-');
          final target = File('${root.path}/42.yaml');
          final owner = ProfileRecoveryOwner(brand, 'owner');
          var fail = true;
          final removed = <String>[];
          try {
            await target.writeAsString('old');
            final op = await XbProfileFileWrite.create(
              targetPath: target.path,
              bytes: Uint8List.fromList('candidate'.codeUnits),
              ensureCurrent: () {},
              recoveryOwner: owner,
              remove: (entry) async {
                final name = entry is Directory
                    ? 'directory'
                    : entry.uri.pathSegments.last;
                if (fail && name == failAt) {
                  throw FileSystemException(
                    'fixture locked',
                    entry.path,
                    const OSError('sharing', 32),
                  );
                }
                await entry.delete();
                removed.add(name);
              },
            );
            await op.backup.writeAsString('old');
            await File(
              '${op.directory.path}/owner.pending',
            ).writeAsString('pending');
            expect(await op.cleanup(), isA<FileSystemException>());
            if (failAt != 'directory') {
              expect(
                await File('${op.directory.path}/owner.json').exists(),
                isTrue,
              );
            }
            if (failAt == 'previous.yaml') {
              expect(removed, ['candidate.yaml']);
              expect(await op.backup.readAsString(), 'old');
            }
            if (failAt == 'candidate.yaml') expect(removed, isEmpty);
            expect(await target.readAsString(), 'old');
            fail = false;
            if (failAt == 'directory') {
              expect(await op.directory.list().toList(), isEmpty);
              expect(await op.cleanup(), isNull);
            } else {
              await XbProfileFileWrite.cleanupOwned(
                targetPath: target.path,
                owner: owner,
              );
            }
            expect(await op.directory.exists(), isFalse);
          } finally {
            await root.delete(recursive: true);
          }
        },
      );
    }
    test(
      '$brand reappeared payload retains marker after initial deletions',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'xb-clean-reappear-',
        );
        final owner = ProfileRecoveryOwner(brand, 'owner');
        try {
          late XbProfileFileWrite op;
          op = await XbProfileFileWrite.create(
            targetPath: '${root.path}/42.yaml',
            bytes: Uint8List(0),
            ensureCurrent: () {},
            recoveryOwner: owner,
            remove: (entry) async {
              await entry.delete();
              if (entry.path == op.backup.path) {
                await op.candidate.writeAsString('late');
              }
            },
          );
          await op.backup.writeAsString('old');
          expect(await op.cleanup(), isA<FileSystemException>());
          expect(
            await File('${op.directory.path}/owner.json').exists(),
            isTrue,
          );
          expect(await op.candidate.readAsString(), 'late');
          await XbProfileFileWrite.cleanupOwned(
            targetPath: '${root.path}/42.yaml',
            owner: owner,
          );
          expect(await op.directory.exists(), isFalse);
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
    for (final unexpected in ['file', 'directory', 'link']) {
      test(
        '$brand in-flight cleanup rejects unexpected $unexpected before removing marker',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'xb-clean-unknown-',
          );
          final owner = ProfileRecoveryOwner(brand, 'owner');
          try {
            final op = await XbProfileFileWrite.create(
              targetPath: '${root.path}/42.yaml',
              bytes: Uint8List(0),
              ensureCurrent: () {},
              recoveryOwner: owner,
            );
            final path = '${op.directory.path}/foreign';
            final external = File('${root.path}/external');
            await external.writeAsString('keep');
            if (unexpected == 'file') await File(path).writeAsString('keep');
            if (unexpected == 'directory') await Directory(path).create();
            if (unexpected == 'link') {
              if (Platform.isWindows) return;
              await Link(path).create(external.path);
            }
            expect(await op.cleanup(), isA<FileSystemException>());
            expect(
              await File('${op.directory.path}/owner.json').exists(),
              isTrue,
            );
            expect(await op.candidate.exists(), isTrue);
            expect(await external.readAsString(), 'keep');
          } finally {
            await root.delete(recursive: true);
          }
        },
      );
    }
    for (final kind in ['json', 'utf8', 'schema', 'shape', 'identity']) {
      test(
        '$brand $kind metadata is retained without blocking either account',
        () async {
          final root = await Directory.systemTemp.createTemp('xb-warning-');
          final target = File('${root.path}/42.yaml');
          final warnings = <ProfileRecoveryWarning>[];
          final diagnostics = ProfileRecoveryDiagnostics(warnings.add);
          try {
            final bad = await XbProfileFileWrite.create(
              targetPath: target.path,
              bytes: Uint8List.fromList([1]),
              ensureCurrent: () {},
              recoveryOwner: ProfileRecoveryOwner(brand, 'old'),
            );
            final marker = File('${bad.directory.path}/owner.json');
            if (kind == 'utf8') {
              await marker.writeAsBytes([255]);
            } else {
              await marker.writeAsString(switch (kind) {
                'json' => '{',
                'schema' => jsonEncode({
                  'schema': 2,
                  'flavor': brand,
                  'owner': 'old',
                  'profile': '42.yaml',
                }),
                'shape' => '[]',
                _ => '{"schema":1}',
              });
            }
            for (final account in ['a', 'b', 'a']) {
              final owner = ProfileRecoveryOwner(brand, account);
              final own = await XbProfileFileWrite.create(
                targetPath: target.path,
                bytes: Uint8List.fromList([2]),
                ensureCurrent: () {},
                recoveryOwner: owner,
              );
              await XbProfileFileWrite.cleanupOwned(
                targetPath: target.path,
                owner: owner,
                diagnostics: diagnostics,
              );
              expect(await own.directory.exists(), isFalse);
              expect(await bad.candidate.exists(), isTrue);
            }
            expect(warnings, hasLength(1));
            expect(warnings.single, switch (kind) {
              'json' || 'utf8' => ProfileRecoveryWarning.malformedMetadata,
              'identity' => ProfileRecoveryWarning.invalidIdentity,
              _ => ProfileRecoveryWarning.unsupportedSchema,
            });
          } finally {
            await root.delete(recursive: true);
          }
        },
      );
    }
    test(
      '$brand disappearing marker does not stop remaining owned cleanup',
      () async {
        final root = await Directory.systemTemp.createTemp('xb-race-');
        final target = File('${root.path}/42.yaml');
        final owner = ProfileRecoveryOwner(brand, 'a');
        try {
          final gone = await XbProfileFileWrite.create(
            targetPath: target.path,
            bytes: Uint8List(0),
            ensureCurrent: () {},
            recoveryOwner: ProfileRecoveryOwner(brand, 'b'),
          );
          final own = await XbProfileFileWrite.create(
            targetPath: target.path,
            bytes: Uint8List(0),
            ensureCurrent: () {},
            recoveryOwner: owner,
          );
          await XbProfileFileWrite.cleanupOwned(
            targetPath: target.path,
            owner: owner,
            readMetadata: (file) async {
              if (file.parent.path == gone.directory.path) {
                await gone.directory.delete(recursive: true);
              }
              return file.readAsBytes();
            },
          );
          expect(await gone.directory.exists(), isFalse);
          expect(await own.directory.exists(), isFalse);
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
    for (final code in [2, 5, 13, 1117]) {
      test(
        '$brand read error $code remains a failure with recovery retained',
        () async {
          final root = await Directory.systemTemp.createTemp('xb-read-error-');
          final target = File('${root.path}/42.yaml');
          final owner = ProfileRecoveryOwner(brand, 'a');
          try {
            final op = await XbProfileFileWrite.create(
              targetPath: target.path,
              bytes: Uint8List(0),
              ensureCurrent: () {},
              recoveryOwner: owner,
            );
            await expectLater(
              XbProfileFileWrite.cleanupOwned(
                targetPath: target.path,
                owner: owner,
                readMetadata: (file) async {
                  throw FileSystemException(
                    'fixture',
                    file.path,
                    OSError('fixture', code),
                  );
                },
              ),
              throwsA(isA<FileSystemException>()),
            );
            expect(await op.candidate.exists(), isTrue);
            expect(
              await File('${op.directory.path}/owner.json').exists(),
              isTrue,
            );
          } finally {
            await root.delete(recursive: true);
          }
        },
      );
    }
    for (final kind in ['unknown', 'link', 'cancel']) {
      test('$brand $kind cleanup retains recovery and external data', () async {
        final root = await Directory.systemTemp.createTemp('xb-owned-');
        final target = File('${root.path}/42.yaml');
        final owner = ProfileRecoveryOwner(brand, 'a');
        try {
          final op = await XbProfileFileWrite.create(
            targetPath: target.path,
            bytes: Uint8List.fromList([1]),
            ensureCurrent: () {},
            recoveryOwner: owner,
          );
          final external = File('${root.path}/external');
          await external.writeAsString('keep');
          if (kind == 'unknown') {
            await File('${op.directory.path}/unexpected').writeAsString('keep');
          }
          if (kind == 'link') {
            if (Platform.isWindows) return;
            await op.candidate.delete();
            await Link(op.candidate.path).create(external.path);
          }
          await expectLater(
            XbProfileFileWrite.cleanupOwned(
              targetPath: target.path,
              owner: owner,
              ensureCurrent: kind == 'cancel'
                  ? () {
                      throw StateError('cancelled');
                    }
                  : null,
            ),
            throwsA(anything),
          );
          expect(await op.directory.exists(), isTrue);
          expect(await external.readAsString(), 'keep');
          expect(
            await File('${op.directory.path}/owner.json').exists(),
            isTrue,
          );
        } finally {
          await root.delete(recursive: true);
        }
      });
    }
  }
}
