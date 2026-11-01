import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/xb_profile_file_write.dart';
import 'package:fl_clash/xboard/services/profile_recovery_owner.dart';

void main() {
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
    for (final kind in ['unknown', 'link', 'metadata', 'cancel']) {
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
          if (kind == 'metadata') {
            await File('${op.directory.path}/owner.json').writeAsString('{');
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
          if (kind != 'metadata') {
            expect(
              await File('${op.directory.path}/owner.json').exists(),
              isTrue,
            );
          }
        } finally {
          await root.delete(recursive: true);
        }
      });
    }
  }
}
