import 'dart:io';
import 'dart:typed_data';

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
