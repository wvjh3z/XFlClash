import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/preferences_store.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/xboard/config/xb_tls_defaults.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/sentry_reporting_preference_provider.dart';
import 'package:fl_clash/xboard/sdk/secure_storage_token_storage.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';
import 'package:fl_clash/xboard/services/sentry_reporting_preference.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show TokenStorage;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Directory directory;
  late String path;
  late SharedPreferencesStorePlatform previousStore;
  late Map<String, String> secureValues;
  var failSecureWrite = false;

  void reopen() {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        AtomicFilePreferencesStore(Future.value(path));
  }

  Future<Directory> blockWrites() async {
    final blocker = Directory('$path.$pid.tmp');
    await blocker.create();
    await File(p.join(blocker.path, 'fixture')).writeAsString('keep');
    return blocker;
  }

  Future<Map<String, dynamic>> disk() async =>
      jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;

  Future<TokenStorage> openToken(String brand) async {
    final storage = await SecureStorageTokenStorage.create(
      fallbackAesKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
      namespace: brand,
      allowUnscopedLegacy: false,
    );
    await storage.ready;
    return storage;
  }

  setUp(() async {
    previousStore = SharedPreferencesStorePlatform.instance;
    directory = await Directory.systemTemp.createTemp('prefs-business-');
    path = p.join(directory.path, 'shared_preferences.json');
    await File(path).writeAsString(jsonEncode({'other': 'untouched'}));
    secureValues = {};
    failSecureWrite = false;
    reopen();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          return secureValues[key];
        case 'write':
          if (failSecureWrite) {
            throw PlatformException(code: 'fixture_write');
          }
          secureValues[key] = args['value'] as String;
          return null;
        case 'delete':
          secureValues.remove(key);
          return null;
        default:
          throw StateError('Unexpected secure operation');
      }
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    XboardConfig.resetForTest();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = previousStore;
    await directory.delete(recursive: true);
  });

  for (final brand in ['brand_a', 'brand_b']) {
    for (final fallback in [false, true]) {
      test('$brand fallback=$fallback rejected token cannot become authoritative',
          () async {
        failSecureWrite = fallback;
        final storage = await openToken(brand);
        await storage.writeToken('synthetic-old');
        final recordKey = 'flutter.${kXbAccessTokenKey}_${brand}_record_v2';
        final before = (await disk())[recordKey];
        final blocker = await blockWrites();
        await expectLater(storage.writeToken('synthetic-rejected'), throwsStateError);
        expect((await disk())[recordKey], before);
        expect(await storage.readToken(), 'synthetic-old');
        await blocker.delete(recursive: true);
        final prefs = await SharedPreferences.getInstance();
        expect(await prefs.setBool('unrelated', true), isTrue);
        expect((await disk())[recordKey], before);
        reopen();
        final recovered = await openToken(brand);
        expect(await recovered.readToken(), 'synthetic-old');
        await recovered.writeToken('synthetic-retry');
        reopen();
        expect(await (await openToken(brand)).readToken(), 'synthetic-retry');
        expect((await disk())['other'], 'untouched');
      });
    }

    test('$brand rejected logout stays a failure until explicit retry', () async {
      final storage = await openToken(brand);
      await storage.writeToken('synthetic-old');
      final blocker = await blockWrites();
      await expectLater(storage.deleteToken(), throwsStateError);
      await blocker.delete(recursive: true);
      final prefs = await SharedPreferences.getInstance();
      expect(await prefs.setBool('unrelated', true), isTrue);
      reopen();
      final recovered = await openToken(brand);
      expect(await recovered.readToken(), 'synthetic-old');
      await recovered.deleteToken();
      reopen();
      expect(await (await openToken(brand)).readToken(), isNull);
    });

    for (final phase in ['marker', 'save', 'complete']) {
      test('$brand TLS $phase write failure retains recoverable disk state',
          () async {
        XboardConfig.bind(XboardConfig(
          subscribeUserAgent: 'test',
          devApiEndpoint: '',
          devSubscriptionEndpoint: '',
          debug: false,
          kIsTest: true,
          flavorId: brand,
          formA: true,
        ));
        final prefs = await SharedPreferences.getInstance();
        Directory? blocker;
        var fault = true;
        if (phase == 'marker') blocker = await blockWrites();
        Future<Config> boot() => xbMigrateWithInitialTlsDefault(
              migrate: () async {
                final raw = prefs.getString(configKey);
                return raw == null
                    ? const Config(themeProps: defaultThemeProps)
                    : Config.fromJson(jsonDecode(raw) as Map<String, dynamic>);
              },
              save: (config) async {
                if (fault && phase == 'save') blocker = await blockWrites();
                final saved = await prefs.setString(configKey, jsonEncode(config));
                if (fault && phase == 'complete') blocker = await blockWrites();
                return saved;
              },
            );
        await expectLater(boot(), throwsStateError);
        final before = await disk();
        expect(before['flutter.$xbInitialTlsPendingKey'],
            phase == 'marker' ? isNull : isTrue);
        await blocker!.delete(recursive: true);
        fault = false;
        expect(await prefs.setBool('unrelated', true), isTrue);
        final after = await disk();
        for (final entry in before.entries) {
          expect(after[entry.key], entry.value);
        }
        expect(after['flutter.$xbInitialTlsPendingKey'],
            phase == 'marker' ? isNull : isTrue);
        expect((await boot()).appSettingProps.checkCertificate, isFalse);
        reopen();
        final fresh = await SharedPreferences.getInstance();
        expect(fresh.containsKey(xbInitialTlsPendingKey), isFalse);
        final config = jsonDecode(fresh.getString(configKey)!) as Map;
        expect((config['appSettingProps'] as Map)['checkCertificate'], isFalse);
      });
    }
  }

  test('Sentry real-file failure preserves UI/runtime; retry requires restart',
      () async {
    final prefs = await SharedPreferences.getInstance();
    expect(await prefs.setBool(kSentryReportingEnabledKey, true), isTrue);
    final applied = <bool>[];
    var needsRestart = false;
    final container = ProviderContainer(overrides: [
      sentryReportingConfiguredProvider.overrideWithValue(true),
      sentryReportingRestartRequiredProvider.overrideWithValue(() => needsRestart),
      sentryReportingApplyOptOutProvider.overrideWithValue((value) async {
        applied.add(value);
        needsRestart = true;
        throw const SentryRestartRequiredException();
      }),
    ]);
    addTearDown(container.dispose);
    await container.read(sentryReportingPreferenceProvider.future);
    final notifier = container.read(sentryReportingPreferenceProvider.notifier);
    final blocker = await blockWrites();
    expect(await notifier.setEnabled(false), SentryReportingChangeResult.persistenceFailed);
    expect(container.read(sentryReportingPreferenceProvider).requireValue.enabled, isTrue);
    expect(applied, isEmpty);
    await blocker.delete(recursive: true);
    expect(await prefs.setBool('unrelated', true), isTrue);
    expect((await disk())['flutter.$kSentryReportingEnabledKey'], isTrue);
    expect(await notifier.setEnabled(false), SentryReportingChangeResult.restartRequired);
    expect(applied, [true]);
    expect(container.read(sentryReportingPreferenceProvider).requireValue.restartRequired, isTrue);
    reopen();
    expect(await SentryReportingPreferenceStore().readEnabled(), isFalse);
  });
}
