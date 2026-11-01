import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/xboard/services/riverpod_profile_sync_port.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/services/xb_profile_file_write.dart';

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
    for (final scenario in [
      'unavailable',
      'disconnected',
      'transport_error',
      'other_error',
      'invalid',
      'cancel',
      'db_failure',
      'success',
      'cleanup_failure',
      'owned_cleanup_success',
      'owned_cleanup_logout',
    ]) {
      test('$brand production staged validation: $scenario', () async {
        final dir = await Directory.systemTemp.createTemp('xb-validation-');
        final target = File('${dir.path}/42.yaml');
        await target.writeAsString('old-config');
        final db = Database(NativeDatabase.memory());
        final core = _Core();
        final owner = ProfileRecoveryOwner(brand, 'owner-a');
        final recovery = await XbProfileFileWrite.create(
          targetPath: target.path,
          bytes: Uint8List.fromList('stale'.codeUnits),
          ensureCurrent: () {},
          recoveryOwner: owner,
        );

        var current = true;
        final entered = Completer<void>();
        final release = Completer<void>();
        when(() => core.validateConfig(any())).thenAnswer((call) async {
          final file = File(call.positionalArguments.first as String);
          expect(await file.readAsString(), 'proxies: []');
          expect(await target.readAsString(), 'old-config');
          if ([
            'unavailable',
            'disconnected',
            'transport_error',
            'other_error',
          ].contains(scenario)) {
            throw CoreMethodException(
              code: switch (scenario) {
                'unavailable' => 'no_response',
                'disconnected' => 'transport_disconnected',
                'transport_error' => 'transport_error',
                _ => 'invalid_argument',
              },
              message: 'fixture unavailable',
            );
          }
          if (scenario == 'cancel') {
            entered.complete();
            await release.future;
          }
          return scenario == 'invalid' ? 'invalid fixture' : '';
        });
        when(() => core.convertProxies(any())).thenAnswer((_) async => []);
        if (scenario == 'cleanup_failure') {
          await File(
            '${recovery.directory.path}/unexpected',
          ).writeAsString('keep');
        }
        final provider = Provider(
          (ref) => RiverpodProfileSyncPort(
            ref,
            profileDatabase: db,
            profilePath: (id) async => '${dir.path}/$id.yaml',
          ),
        );
        final container = ProviderContainer(
          overrides: [
            profilesStreamProvider.overrideWith(
              (ref) => db.profilesDao.query().watch(),
            ),
            currentProfileIdProvider.overrideWith(_Selected.new),
            initProvider.overrideWith(_NotReady.new),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          ],
        );
        container.listen(profilesProvider, (_, _) {});
        container.listen(currentProfileIdProvider, (_, _) {});
        try {
          await db.profiles.put(
            Profile.normal(label: 'old').copyWith(id: 42).toCompanion(),
          );
          await container.read(profilesStreamProvider.future);
          if (scenario == 'db_failure') {
            await db.customStatement(
              "CREATE TRIGGER reject_write BEFORE UPDATE ON profiles BEGIN SELECT RAISE(ABORT, 'reject fixture'); END",
            );
          }
          final flight = container
              .read(provider)
              .putFileProfile(
                profileId: 42,
                recoveryOwner: owner,
                yamlBytes: Uint8List.fromList('proxies: []'.codeUnits),
                label: brand,
                isSessionCurrent: () => current,
              );
          if (scenario == 'cancel') {
            final observed = expectLater(
              flight,
              throwsA(isA<ProfileSyncCancelled>()),
            );
            await entered.future;
            current = false;
            release.complete();
            await observed;
            // Session-end cleanup intentionally removes the ended owner's file.
            expect(await target.exists(), isFalse);
          } else if (scenario == 'cleanup_failure') {
            await expectLater(flight, throwsA(isA<FileSystemException>()));
            expect(await target.readAsString(), 'proxies: []');
            expect(await recovery.directory.exists(), isTrue);
            expect(await db.profilesDao.query().get(), hasLength(1));
            await File('${recovery.directory.path}/unexpected').delete();
            await container
                .read(provider)
                .deleteProfile(42, recoveryOwner: owner);
            expect(await target.exists(), isFalse);
            expect(await recovery.directory.exists(), isFalse);
            expect(await db.profilesDao.query().get(), isEmpty);
          } else if ([
            'success',
            'owned_cleanup_success',
            'owned_cleanup_logout',
          ].contains(scenario)) {
            expect(await flight, 42);
            expect(await target.readAsString(), 'proxies: []');
            expect(await recovery.directory.exists(), isFalse);
            if (scenario == 'owned_cleanup_logout') {
              final late = await XbProfileFileWrite.create(
                targetPath: target.path,
                bytes: Uint8List(0),
                ensureCurrent: () {},
                recoveryOwner: owner,
              );
              await container
                  .read(provider)
                  .deleteProfile(42, recoveryOwner: owner);
              expect(await late.directory.exists(), isFalse);
              expect(await target.exists(), isFalse);
            }
          } else {
            await expectLater(
              flight,
              [
                    'unavailable',
                    'disconnected',
                    'transport_error',
                  ].contains(scenario)
                  ? throwsA(isA<ProfileValidationUnavailable>())
                  : scenario == 'other_error'
                  ? throwsA(isA<CoreMethodException>())
                  : throwsA(anything),
            );
            expect(await target.readAsString(), 'old-config');
            expect(await recovery.directory.exists(), isTrue);
          }
          await recovery.directory.exists().then((exists) async {
            if (exists) await recovery.directory.delete(recursive: true);
          });
          expect(
            await dir
                .list()
                .where((e) => e.path.contains('.xb-profile-'))
                .toList(),
            isEmpty,
          );
        } finally {
          container.dispose();
          await db.close();
          await dir.delete(recursive: true);
        }
      });
    }
  }
}
