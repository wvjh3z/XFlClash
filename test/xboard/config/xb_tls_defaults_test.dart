import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise failures below the SharedPreferences cache.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/migration.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/config/xb_tls_defaults.dart';

class _Disk extends InMemorySharedPreferencesStore {
  _Disk() : super.empty();
  String? faultKey;
  String? fault;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.$faultKey') {
      if (fault == 'throw') throw StateError('controlled write failure');
      if (fault == 'false') return false;
      if (fault == 'lost') return true;
    }
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (key == 'flutter.$faultKey') {
      if (fault == 'throw') throw StateError('controlled remove failure');
      if (fault == 'false') return false;
      if (fault == 'lost') return true;
    }
    return super.remove(key);
  }
}

class _Store implements MigrationStore {
  _Store(this.prefs);
  final SharedPreferences prefs;
  @override
  Future<bool> get isAvailable async => true;
  @override
  Future<Map<String, Object?>?> getConfigMap() async {
    final raw = prefs.getString(configKey);
    return raw == null ? null : jsonDecode(raw) as Map<String, Object?>;
  }

  @override
  Future<Map<String, Object?>?> getClashConfigMap() async => null;
  @override
  Future<int> getVersion() async => prefs.getInt('fixture_version') ?? 0;
  @override
  Future<void> setVersion(int v) async {
    await prefs.setInt('fixture_version', v);
  }

  @override
  Future<int> getUpgradeVersion() async => prefs.getInt('fixture_upgrade') ?? 0;
  @override
  Future<void> setUpgradeVersion(int v) async {
    await prefs.setInt('fixture_upgrade', v);
  }

  @override
  Future<void> restore(MigrationData data) async {}
  @override
  Future<void> clearClashConfig() async {}
  @override
  Future<bool> saveConfig(Config config) =>
      prefs.setString(configKey, jsonEncode(config));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Disk disk;
  setUp(() {
    SharedPreferences.resetStatic();
    disk = _Disk();
    SharedPreferencesStorePlatform.instance = disk;
  });
  tearDown(() {
    XboardConfig.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });
  Future<_Store> reopen() async {
    SharedPreferences.resetStatic();
    return _Store(await SharedPreferences.getInstance());
  }

  Future<Config> boot(_Store store) => xbMigrateWithInitialTlsDefault(
    migrate: Migration(store: store).run,
    save: store.saveConfig,
  );
  for (final brand in ['brand_a', 'brand_b']) {
    group(brand, () {
      setUp(
        () => XboardConfig.bind(
          XboardConfig(
            subscribeUserAgent: 'test',
            devApiEndpoint: '',
            devSubscriptionEndpoint: '',
            debug: false,
            kIsTest: true,
            flavorId: brand,
            formA: true,
          ),
        ),
      );
      test(
        'fresh default persists; completed initialization respects later user choice',
        () async {
          var store = await reopen();
          expect((await boot(store)).appSettingProps.checkCertificate, isFalse);
          await store.prefs.reload();
          expect(store.prefs.containsKey(xbInitialTlsPendingKey), isFalse);
          for (final verify in [true, false]) {
            await store.saveConfig(
              Config(
                themeProps: defaultThemeProps,
                appSettingProps: AppSettingProps(checkCertificate: verify),
              ),
            );
            store = await reopen();
            expect(
              (await boot(store)).appSettingProps.checkCertificate,
              verify,
            );
          }
        },
      );
      for (final boundary in [
        'before_migration',
        'after_migration',
        'after_save',
      ]) {
        test(
          'interruption $boundary resumes without accepting migration default',
          () async {
            final store = await reopen();
            await expectLater(
              xbMigrateWithInitialTlsDefault(
                migrate: () async {
                  if (boundary == 'before_migration') {
                    throw StateError('interrupted');
                  }
                  final config = await Migration(store: store).run();
                  if (boundary == 'after_migration') {
                    throw StateError('interrupted');
                  }
                  return config;
                },
                save: (c) async {
                  await store.saveConfig(c);
                  throw StateError('interrupted');
                },
              ),
              throwsStateError,
            );
            final next = await reopen();
            expect(next.prefs.getBool(xbInitialTlsPendingKey), isTrue);
            expect(
              (await boot(next)).appSettingProps.checkCertificate,
              isFalse,
            );
            await next.prefs.reload();
            expect(next.prefs.containsKey(xbInitialTlsPendingKey), isFalse);
          },
        );
      }
      for (final phase in ['marker', 'save', 'complete']) {
        for (final fault in ['false', 'throw', 'lost']) {
          test(
            '$phase $fault stops startup and retry succeeds after reopening',
            () async {
              final store = await reopen();
              var enteredMigration = false;
              if (phase == 'marker') {
                disk.faultKey = xbInitialTlsPendingKey;
                disk.fault = fault;
              }
              await expectLater(
                xbMigrateWithInitialTlsDefault(
                  migrate: () async {
                    enteredMigration = true;
                    return Migration(store: store).run();
                  },
                  save: (c) async {
                    if (phase == 'save') {
                      disk.faultKey = configKey;
                      disk.fault = fault;
                    }
                    final ok = await store.saveConfig(c);
                    if (phase == 'complete') {
                      disk.faultKey = xbInitialTlsPendingKey;
                      disk.fault = fault;
                    }
                    return ok;
                  },
                ),
                throwsStateError,
              );
              if (phase == 'marker') expect(enteredMigration, isFalse);
              disk.faultKey = null;
              disk.fault = null;
              final next = await reopen();
              expect(
                (await boot(next)).appSettingProps.checkCertificate,
                isFalse,
              );
              await next.prefs.reload();
              expect(next.prefs.containsKey(xbInitialTlsPendingKey), isFalse);
            },
          );
        }
      }
      for (final key in [configKey, clashConfigKey]) {
        test(
          'existing $key including corrupt JSON never receives first-install default',
          () async {
            final store = await reopen();
            await store.prefs.setString(key, 'not JSON');
            const original = Config(themeProps: defaultThemeProps);
            final result = await xbMigrateWithInitialTlsDefault(
              migrate: () async => original,
              save: (_) async => fail('must not overwrite existing choice'),
            );
            expect(identical(result, original), isTrue);
            expect(store.prefs.containsKey(xbInitialTlsPendingKey), isFalse);
          },
        );
      }
      test('non-brand migration remains untouched', () async {
        XboardConfig.resetForTest();
        const original = Config(themeProps: defaultThemeProps);
        final result = await xbMigrateWithInitialTlsDefault(
          migrate: () async => original,
          save: (_) async => fail('non-brand save'),
        );
        expect(identical(result, original), isTrue);
      });
    });
  }
}
