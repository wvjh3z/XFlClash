import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/xb_profile_file_write.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    late Directory root;
    late File target;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('xb-write-test-');
      target = File('${root.path}/profile.yaml');
      await target.writeAsString('old');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      '$brand bounded sharing retry succeeds without deleting old file',
      () async {
        var attempts = 0;
        final waits = <Duration>[];
        final op = await XbProfileFileWrite.create(
          targetPath: target.path,
          bytes: Uint8List.fromList('new'.codeUnits),
          ensureCurrent: () {},
          windows: true,
          wait: (d) async {
            waits.add(d);
            expect(await target.readAsString(), 'old');
          },
          rename: (file, path) async {
            attempts++;
            if (attempts < 3) {
              throw FileSystemException(
                'busy',
                path,
                const OSError('sharing', 32),
              );
            }
            return file.rename(path);
          },
        );
        await op.publish();
        op.commit();
        expect(attempts, 3);
        expect(waits.length, 2);
        expect(await target.readAsString(), 'new');
        expect(await op.cleanup(), isNull);
        expect(await op.directory.exists(), isFalse);
      },
    );

    for (final code in [32, 33, 5, 183]) {
      test(
        '$brand failure $code retains old config and bounded attempts',
        () async {
          var attempts = 0;
          final op = await XbProfileFileWrite.create(
            targetPath: target.path,
            bytes: Uint8List.fromList([1]),
            ensureCurrent: () {},
            windows: true,
            wait: (_) async {},
            rename: (file, path) async {
              attempts++;
              throw FileSystemException('fail', path, OSError('fixture', code));
            },
          );
          await expectLater(op.publish(), throwsA(isA<FileSystemException>()));
          expect(attempts, code == 5 || code == 32 || code == 33 ? 4 : 1);
          expect(await target.readAsString(), 'old');
          await op.rollback();
          expect(await op.cleanup(), isNull);
          expect(await op.directory.exists(), isFalse);
        },
      );
    }

    test('$brand cancel during retry prevents another publication', () async {
      var current = true;
      var attempts = 0;
      final op = await XbProfileFileWrite.create(
        targetPath: target.path,
        bytes: Uint8List.fromList([1]),
        ensureCurrent: () {
          if (!current) throw const ProfileSyncCancelled();
        },
        windows: true,
        wait: (_) async {
          current = false;
        },
        rename: (f, p) async {
          attempts++;
          throw FileSystemException('busy', p, const OSError('sharing', 32));
        },
      );
      await expectLater(op.publish(), throwsA(isA<ProfileSyncCancelled>()));
      expect(attempts, 1);
      expect(await target.readAsString(), 'old');
      await op.cleanup();
      expect(await op.directory.exists(), isFalse);
    });

    for (final cancel in [false, true]) {
      test(
        '$brand snapshot recheck rename share budget; cancel=$cancel',
        () async {
          var reads = 0, renames = 0, current = true;
          final waits = <Duration>[];
          final op = await XbProfileFileWrite.create(
            targetPath: target.path,
            bytes: Uint8List.fromList('new'.codeUnits),
            windows: true,
            ensureCurrent: () {
              if (!current) throw const ProfileSyncCancelled();
            },
            readTarget: () async {
              reads++;
              if (reads == 1 || reads == 3) {
                throw FileSystemException(
                  'held',
                  target.path,
                  const OSError('sharing', 32),
                );
              }
              return target.readAsBytes();
            },
            wait: (d) async {
              waits.add(d);
              if (cancel) current = false;
            },
            rename: (f, p) async {
              renames++;
              throw FileSystemException(
                'held',
                p,
                const OSError('sharing', 32),
              );
            },
          );
          await expectLater(
            op.publish(),
            throwsA(
              cancel ? isA<ProfileSyncCancelled>() : isA<FileSystemException>(),
            ),
          );
          expect(
            waits,
            cancel
                ? [const Duration(milliseconds: 100)]
                : const [
                    Duration(milliseconds: 100),
                    Duration(milliseconds: 200),
                    Duration(milliseconds: 400),
                  ],
          );
          expect(reads, cancel ? 1 : 5);
          expect(renames, cancel ? 0 : 2);
          expect(await target.readAsString(), 'old');
          await op.cleanup();
          expect(await op.directory.exists(), isFalse);
        },
      );
    }
    test(
      '$brand changed snapshot after read retry is never overwritten',
      () async {
        var reads = 0;
        final op = await XbProfileFileWrite.create(
          targetPath: target.path,
          bytes: Uint8List.fromList('new'.codeUnits),
          windows: true,
          ensureCurrent: () {},
          readTarget: () async {
            reads++;
            if (reads == 2) {
              throw FileSystemException(
                'held',
                target.path,
                const OSError('sharing', 32),
              );
            }
            return target.readAsBytes();
          },
          wait: (_) async {
            await target.writeAsString('external');
          },
        );
        await expectLater(op.publish(), throwsA(isA<FileSystemException>()));
        expect(reads, 3);
        expect(await target.readAsString(), 'external');
        await op.cleanup();
        expect(await op.directory.exists(), isFalse);
      },
    );
    test('$brand database failure can restore old file', () async {
      final op = await XbProfileFileWrite.create(
        targetPath: target.path,
        bytes: Uint8List.fromList('new'.codeUnits),
        ensureCurrent: () {},
      );
      await op.publish();
      await op.rollback();
      await op.cleanup();
      expect(await target.readAsString(), 'old');
      expect(await op.directory.exists(), isFalse);
    });
    test('$brand failed rollback preserves recovery material', () async {
      var attempts = 0;
      final op = await XbProfileFileWrite.create(
        targetPath: target.path,
        bytes: Uint8List.fromList('new'.codeUnits),
        ensureCurrent: () {},
        rename: (f, p) async {
          if (++attempts == 2) throw FileSystemException('recovery blocked', p);
          return f.rename(p);
        },
      );
      await op.publish();
      await expectLater(op.rollback(), throwsA(isA<FileSystemException>()));
      await op.cleanup();
      expect(await op.backup.readAsString(), 'old');
      expect(await op.directory.exists(), isTrue);
    });
    test('$brand external change is not overwritten by rollback', () async {
      final op = await XbProfileFileWrite.create(
        targetPath: target.path,
        bytes: Uint8List.fromList('new'.codeUnits),
        ensureCurrent: () {},
      );
      await op.publish();
      await target.writeAsString('external');
      await expectLater(op.rollback(), throwsA(isA<FileSystemException>()));
      await op.cleanup();
      expect(await target.readAsString(), 'external');
      expect(await op.backup.readAsString(), 'old');
    });
    test(
      '$brand directory and symlink are rejected without changing destination',
      () async {
        await target.delete();
        await Directory(target.path).create();
        final op = await XbProfileFileWrite.create(
          targetPath: target.path,
          bytes: Uint8List.fromList([1]),
          ensureCurrent: () {},
        );
        await expectLater(op.publish(), throwsA(isA<FileSystemException>()));
        await op.cleanup();
        expect(await Directory(target.path).exists(), isTrue);
        if (!Platform.isWindows) {
          await Directory(target.path).delete();
          final external = File('${root.path}/external');
          await external.writeAsString('external');
          await Link(target.path).create(external.path);
          final other = await XbProfileFileWrite.create(
            targetPath: target.path,
            bytes: Uint8List.fromList([1]),
            ensureCurrent: () {},
          );
          await expectLater(
            other.publish(),
            throwsA(isA<FileSystemException>()),
          );
          await other.cleanup();
          expect(await external.readAsString(), 'external');
        }
      },
    );
    test(
      '$brand validation failure cleans staging without changing old config',
      () async {
        final op = await XbProfileFileWrite.create(
          targetPath: target.path,
          bytes: Uint8List.fromList([1]),
          ensureCurrent: () {},
        );
        // A rejected real validator never calls publish.
        await op.cleanup();
        expect(await target.readAsString(), 'old');
        expect(await op.directory.exists(), isFalse);
      },
    );
  }
}
