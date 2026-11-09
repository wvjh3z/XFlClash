/// UB-GAP-16: real guard decisions and production port, controlled Core/OS I/O.
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:fl_clash/common/boot_guard.dart';
import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/services/riverpod_profile_sync_port.dart';
import 'package:fl_clash/xboard/services/xb_profile_file_write.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Core extends Mock implements CoreHandlerInterface {}
class _Selected extends CurrentProfileId {
  _Selected(this.initial);
  final int? initial;
  @override
  int? build() => initial;
}
class _Ready extends Init {
  _Ready(this.initial);
  final bool initial;
  @override
  bool build() => initial;
}
class _Apply extends SetupAction {
  int calls = 0;
  @override
  void build() {}
  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) { calls++; }
}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final priorFailures in [0, 1]) {
      for (final ready in [false, true]) {
        for (final valid in [false, true]) {
          test('UB16 $brand failures=$priorFailures init=$ready valid=$valid', () async {
            BootRecord? record = BootRecord(stage: BootStage.starting,
              profileId: 42, startedAt: 1000, failureCount: priorFailures);
            final guard = BootGuard(supported: true, readRecord: () async => record,
              writeRecord: (value) async { record = value; },
              readExitInfo: () async => null, now: () => 5000);
            final decision = await guard.evaluate(profileId: 42);
            expect(decision.recovery, priorFailures == 0
              ? BootRecovery.skipAutoSetup : BootRecovery.clearProfile);
            // Reproduce bootstrap's decision output; do not claim Android storage.
            final selected = decision.recovery == BootRecovery.clearProfile ? null : 42;
            final directory = await Directory.systemTemp.createTemp('boot-sync-');
            final target = File('${directory.path}/42.yaml');
            await target.writeAsString('old-config');
            final database = Database(NativeDatabase.memory());
            final core = _Core();
            when(() => core.validateConfig(any())).thenAnswer((_) async {
              if (!valid) throw CoreMethodException(code: 'no_response', message: 'fixture');
              return null;
            });
            when(() => core.convertProxies(any())).thenAnswer((_) async => []);
            final apply = _Apply();
            final port = Provider((ref) => RiverpodProfileSyncPort(ref,
              profileDatabase: database, profilePath: (id) async => '${directory.path}/$id.yaml'));
            final container = ProviderContainer(overrides: [
              profilesStreamProvider.overrideWith((ref) => database.profilesDao.query().watch()),
              currentProfileIdProvider.overrideWith(() => _Selected(selected)),
              initProvider.overrideWith(() => _Ready(ready)),
              setupActionProvider.overrideWith(() => apply),
              coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            ]);
            container.listen(profilesProvider, (_, _) {});
            container.listen(currentProfileIdProvider, (_, _) {});
            try {
              await database.profiles.put(Profile.normal(label: 'old').copyWith(id: 42).toCompanion());
              await container.read(profilesStreamProvider.future);
              final operation = container.read(port).putFileProfile(profileId: 42,
                yamlBytes: Uint8List.fromList('proxies: []'.codeUnits), label: brand,
                recoveryOwner: ProfileRecoveryOwner(brand, 'synthetic-owner'));
              if (valid) {
                expect(await operation, 42);
                expect(container.read(currentProfileIdProvider), 42);
                expect(apply.calls, ready ? 1 : 0);
                expect(await target.readAsString(), 'proxies: []');
                // The guard's decision still exists; the port does not consult it.
                expect(guard.decision.isDegraded, isTrue);
              } else {
                await expectLater(operation, throwsA(isA<ProfileValidationUnavailable>()));
                expect(container.read(currentProfileIdProvider), selected);
                expect(apply.calls, 0);
                expect(await target.readAsString(), 'old-config');
              }
            } finally {
              container.dispose();
              await database.close();
              await directory.delete(recursive: true);
            }
          });
        }
      }
    }
  }
}
