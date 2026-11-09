/// G13: post-commit cleanup failure must be distinguished from rolled-back save.
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/xboard/services/riverpod_profile_sync_port.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/services/xb_profile_file_write.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Core extends Mock implements CoreHandlerInterface {}
class _Selected extends CurrentProfileId {
  @override
  int? build() => 42;
}
class _NotReady extends Init {
  @override
  bool build() => false;
}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    test('G13 $brand cleanup error preserves committed row/file across reopen', () async {
      final directory = await Directory.systemTemp.createTemp('postcommit-reopen-');
      final dbFile = File('${directory.path}/database.sqlite');
      final target = File('${directory.path}/42.yaml');
      await target.writeAsString('old-config');
      final owner = ProfileRecoveryOwner(brand, 'synthetic-owner');
      final recovery = await XbProfileFileWrite.create(targetPath: target.path,
        bytes: Uint8List.fromList('older-backup'.codeUnits), ensureCurrent: () {}, recoveryOwner: owner);
      final obstruction = File('${recovery.directory.path}/unexpected');
      await obstruction.writeAsString('owned test obstruction');
      final core = _Core();
      when(() => core.validateConfig(any())).thenAnswer((_) async => null);
      when(() => core.convertProxies(any())).thenAnswer((_) async => []);
      var database = Database(NativeDatabase(dbFile));
      ProviderContainer? container;
      try {
        await database.profiles.put(Profile.normal(label: 'before').copyWith(id: 42).toCompanion());
        for (final obstructed in [true, false]) {
          final currentDb = database;
          final port = Provider((ref) => RiverpodProfileSyncPort(ref,
            profileDatabase: currentDb, profilePath: (id) async => '${directory.path}/$id.yaml'));
          container = ProviderContainer(overrides: [
            profilesStreamProvider.overrideWith((ref) => currentDb.profilesDao.query().watch()),
            currentProfileIdProvider.overrideWith(_Selected.new),
            initProvider.overrideWith(_NotReady.new),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          ]);
          container.listen(profilesProvider, (_, _) {});
          await container.read(profilesStreamProvider.future);
          final operation = container.read(port).putFileProfile(profileId: 42,
            yamlBytes: Uint8List.fromList('proxies: []'.codeUnits), label: 'after', recoveryOwner: owner);
          if (obstructed) {
            await expectLater(operation, throwsA(isA<FileSystemException>()));
            expect(await recovery.directory.exists(), isTrue);
          } else {
            expect(await operation, 42);
            expect(await recovery.directory.exists(), isFalse);
          }
          container.dispose();
          container = null;
          await database.close();
          database = Database(NativeDatabase(dbFile));
          final rows = await database.profilesDao.query().get();
          expect(rows, hasLength(1));
          expect(rows.single.id, 42);
          expect(rows.single.label, 'after');
          expect(await target.readAsString(), 'proxies: []');
          if (obstructed) await obstruction.delete();
        }
      } finally {
        container?.dispose();
        await database.close();
        await directory.delete(recursive: true);
      }
    });
  }
}
