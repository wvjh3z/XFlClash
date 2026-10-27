import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart' as native;
import 'package:fl_clash/xboard/data/xboard_database.dart';
import 'package:drift/drift.dart'
    show QueryInterceptor, QueryExecutor, ApplyInterceptor, driftRuntimeOptions;
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/services/riverpod_profile_sync_port.dart';
import 'package:fl_clash/xboard/storage/profile_database_access.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Inserts extends QueryInterceptor {
  int attempts = 0;
  final ids = <Object?>[];
  Future<void> Function()? onBusy;
  void Function()? onCommit;
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    attempts++;
    ids.add(args.first);
    try {
      final result = await executor.runInsert(statement, args);
      onCommit?.call();
      return result;
    } catch (error) {
      if (profileSqliteException(error)?.resultCode == 5) await onBusy?.call();
      rethrow;
    }
  }
}

class _Selected extends CurrentProfileId {
  @override
  int? build() => null;
}

class _Ready extends Init {
  _Ready(this.ready);
  final bool ready;
  @override
  bool build() => ready;
}

class _Setup extends SetupAction {
  int applies = 0;
  @override
  void build() {}
  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) =>
      applies++;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  for (final brand in ['brand_a', 'brand_b']) {
    test('$brand late save failure cleans owned file after logout', () async {
      final dir = await Directory.systemTemp.createTemp('xb-late-write-');
      final main = Database(openProfileDatabase(File('${dir.path}/main.sqlite')));
      final index = XboardDatabase(native.NativeDatabase(File('${dir.path}/index.sqlite')));
      final started = Completer<void>();
      final gate = Completer<void>();
      var current = true;
      final provider = Provider((ref) => RiverpodProfileSyncPort(
        ref, profileDatabase: main,
        profilePath: (id) async => '${dir.path}/$id.yaml',
        saveProfile: (profile, bytes) async {
          started.complete();
          await gate.future;
          await File('${dir.path}/${profile.id}.yaml').writeAsBytes(bytes);
          throw StateError('fixture failure after target copy');
        },
      ));
      final container = ProviderContainer(overrides: [
        profilesStreamProvider.overrideWith((ref) => main.profilesDao.query().watch()),
        currentProfileIdProvider.overrideWith(_Selected.new),
        initProvider.overrideWith(() => _Ready(false)),
        setupActionProvider.overrideWith(_Setup.new),
      ]);
      container.listen(profilesProvider, (_, _) {});
      container.listen(currentProfileIdProvider, (_, _) {});
      try {
        await main.customSelect('SELECT 1').get();
        await container.read(profilesStreamProvider.future);
        final port = container.read(provider);
        final flight = port.putFileProfile(profileId: 42, yamlBytes: Uint8List.fromList([1,2]), label: brand,
          isSessionCurrent: () => current,
          beforeWrite: (id) => index.putIndex(profileId:id, flavorId:brand, userIdHash:'owner'));
        final observed = expectLater(flight, throwsA(isA<ProfileSyncCancelled>()));
        await started.future;
        current = false;
        await port.deleteProfile(42);
        await index.deleteByProfileId(42);
        gate.complete();
        await observed;
        expect(await File('${dir.path}/42.yaml').exists(), isFalse);
        expect(await index.allRows(), isEmpty);
        expect(await main.profilesDao.query().get(), isEmpty);
      } finally {
        container.dispose(); await index.close(); await main.close();
        await dir.delete(recursive:true);
      }
    });
    test('$brand reservation survives file/main failure and database reopen', () async {
      final dir = await Directory.systemTemp.createTemp('xb-recovery-中文 ');
      final main = Database(openProfileDatabase(File('${dir.path}/main.sqlite')));
      var index = XboardDatabase(native.NativeDatabase(File('${dir.path}/index.sqlite')));
      final setup = _Setup();
      var failSave = true;
      var rejectReservation = false;
      var saves = 0;
      int? reserved;
      final provider = Provider((ref) => RiverpodProfileSyncPort(
        ref,
        profileDatabase: main,
        profilePath: (id) async => '${dir.path}/$id.yaml',
        saveProfile: (profile, bytes) async {
          saves++;
          expect((await index.allRows()).single.profileId, profile.id);
          await File('${dir.path}/${profile.id}.yaml').writeAsBytes(bytes);
          if (failSave) throw StateError('after file write');
          return profile;
        },
      ));
      final container = ProviderContainer(overrides: [
        profilesStreamProvider.overrideWith((ref) => main.profilesDao.query().watch()),
        currentProfileIdProvider.overrideWith(_Selected.new),
        initProvider.overrideWith(() => _Ready(false)),
        setupActionProvider.overrideWith(() => setup),
      ]);
      container.listen(profilesProvider, (_, _) {});
      container.listen(currentProfileIdProvider, (_, _) {});
      try {
        await main.customSelect('SELECT 1').get();
        await container.read(profilesStreamProvider.future);
        Future<int> write(int? id) => container.read(provider).putFileProfile(
          profileId: id, yamlBytes: Uint8List.fromList([1, 2]), label: brand,
          beforeWrite: (id) async {
            if (rejectReservation) throw StateError('index disk failure');
            await index.putIndex(profileId: id, flavorId: brand, userIdHash: 'owner');
            reserved = id;
          },
        );
        rejectReservation = true;
        await expectLater(write(null), throwsStateError);
        expect(saves, 0);
        expect(await index.allRows(), isEmpty);
        rejectReservation = false;
        await expectLater(write(null), throwsStateError);
        final id = reserved!;
        expect(await File('${dir.path}/$id.yaml').exists(), isTrue);
        expect(await main.profilesDao.query().get(), isEmpty);
        await index.close();
        index = XboardDatabase(native.NativeDatabase(File('${dir.path}/index.sqlite')));
        expect((await index.allRows()).single.profileId, id);
        failSave = false;
        expect(await write(id), id);
        expect((await main.profilesDao.query().get()).single.id, id);
        expect((await index.allRows()).single.profileId, id);
        await container.read(provider).deleteProfile(id);
        await index.deleteByProfileId(id);
        expect(await File('${dir.path}/$id.yaml').exists(), isFalse);
        expect(await main.profilesDao.query().get(), isEmpty);
        expect(await index.allRows(), isEmpty);
      } finally {
        container.dispose();
        await index.close();
        await main.close();
        await dir.delete(recursive: true);
      }
    });
    for (final scenario in [
      'recover',
      'update',
      'cold',
      'logout',
      'dispose',
      'logout-after-commit',
      'persistent',
    ]) {
      test(
        '$brand $scenario: real port retries only fixed row, never save/allocate/apply twice',
        () async {
          final dir = await Directory.systemTemp.createTemp('xb-port-');
          final file = File('${dir.path}/database.sqlite');
          final holder = Database(openProfileDatabase(file));
          await holder.customSelect('SELECT 1').get();
          final inserts = _Inserts();
          final db = Database(openProfileDatabase(file).interceptWith(inserts));
          await db.customSelect('SELECT 1').get();
          if (scenario == 'update') {
            await holder.profiles.put(
              const Profile(
                id: 42,
                label: 'old',
                autoUpdateDuration: Duration(days: 1),
              ).toCompanion(),
            );
          }
          final setup = _Setup();
          var current = true;
          var saves = 0;
          var held = true;
          var disposed = false;
          int? savedId;
          final provider = Provider(
            (ref) => RiverpodProfileSyncPort(
              ref,
              profileDatabase: db,
              profilePath: (id) async => '${dir.path}/$id.yaml',
              // Real file I/O, with core validation replaced; no production node data.
              saveProfile: (profile, bytes) async {
                saves++;
                savedId = profile.id;
                await File(
                  '${dir.path}/${profile.id}.yaml',
                ).writeAsBytes(bytes);
                return profile;
              },
            ),
          );
          final container = ProviderContainer(
            overrides: [
              profilesStreamProvider.overrideWith(
                (ref) => db.profilesDao.query().watch(),
              ),
              currentProfileIdProvider.overrideWith(_Selected.new),
              initProvider.overrideWith(() => _Ready(scenario != 'cold')),
              setupActionProvider.overrideWith(() => setup),
            ],
          );
          container.listen(currentProfileIdProvider, (_, _) {});
          container.listen(profilesProvider, (_, _) {});
          await container.read(profilesStreamProvider.future);
          await holder.customStatement('BEGIN IMMEDIATE');
          inserts.onCommit = () {
            if (scenario == 'logout-after-commit') current = false;
          };
          inserts.onBusy = () async {
            if (scenario == 'persistent') return;
            await holder.customStatement('ROLLBACK');
            held = false;
            if (scenario == 'logout') current = false;
            if (scenario == 'dispose') {
              container.dispose();
              disposed = true;
            }
          };
          try {
            final future = container
                .read(provider)
                .putFileProfile(
                  profileId: scenario == 'update' ? 42 : null,
                  yamlBytes: Uint8List.fromList([1, 2, 3]),
                  label: brand == 'brand_a' ? 'OmoFly' : '袋鼠加速',
                  isSessionCurrent: () => current,
                );
            if (['recover', 'update', 'cold'].contains(scenario)) {
              expect(await future, savedId);
              expect(inserts.attempts, 2);
              expect(setup.applies, scenario == 'cold' ? 0 : 1);
              if (scenario == 'update') expect(savedId, 42);
              expect(container.read(currentProfileIdProvider), savedId);
              expect((await db.profilesDao.query().get()).map((p) => p.id), [
                savedId,
              ]);
            } else {
              await expectLater(
                future,
                scenario == 'persistent'
                    ? throwsA(
                        predicate<Object>(
                          (e) => profileSqliteException(e)?.resultCode == 5,
                        ),
                      )
                    : throwsA(isA<ProfileSyncCancelled>()),
              );
              expect(
                inserts.attempts,
                scenario == 'persistent'
                    ? 3
                    : scenario == 'logout-after-commit'
                    ? 2
                    : 1,
              );
              expect(setup.applies, 0);
              if (!disposed) {
                expect(container.read(currentProfileIdProvider), isNull);
              }
              expect(await db.profilesDao.query().get(), isEmpty);
              if (scenario != 'persistent') {
                expect(
                  await File('${dir.path}/$savedId.yaml').exists(),
                  isFalse,
                );
              }
            }
            expect(saves, 1);
            expect(inserts.ids.toSet(), {savedId});
          } finally {
            if (held) await holder.customStatement('ROLLBACK');
            if (!disposed) container.dispose();
            await db.close();
            await holder.close();
            await dir.delete(recursive: true);
          }
        },
      );
    }
  }
}
