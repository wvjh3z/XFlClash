import 'dart:async';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/sentry_reporting_preference_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';
import 'package:fl_clash/xboard/services/sentry_reporting_preference.dart';
import 'package:fl_clash/xboard/xboard_module.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../_fixtures/fake_token_storage.dart';
import '../_fixtures/fake_xboard_sdk.dart';

const _config = XboardConfig(
  subscribeUserAgent: 'Test/1.0 flclash',
  devApiEndpoint: 'https://api.example.invalid',
  devSubscriptionEndpoint: 'https://subscription.example.invalid',
  sentryDsn: 'https://public-key@sentry.example.invalid/1',
  debug: false,
  kIsTest: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeXBoardSDK sdk;
  late _RecordingRuntime runtime;
  ProviderContainer? container;

  setUpAll(() => registerFallbackValue(_TokenStorageFallback()));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SentryBootstrap.resetForTest();
    runtime = _RecordingRuntime();
    SentryBootstrap.setRuntimeForTest(runtime);
    sdk = FakeXBoardSDK();
    when(
      () => sdk.initialize(
        any(),
        panelType: any(named: 'panelType'),
        customStorage: any(named: 'customStorage'),
        proxyUrl: any(named: 'proxyUrl'),
        userAgent: any(named: 'userAgent'),
        httpConfig: any(named: 'httpConfig'),
        useMemoryStorage: any(named: 'useMemoryStorage'),
        enableLogging: any(named: 'enableLogging'),
        usePrintLogger: any(named: 'usePrintLogger'),
        allowNonFlclashUa: any(named: 'allowNonFlclashUa'),
      ),
    ).thenAnswer((_) async {});
  });
  tearDown(() async {
    await XboardModule.dispose();
    container?.dispose();
    container = null;
    if (!SentryBootstrap.restartRequired) {
      await SentryBootstrap.setUserOptOut(true);
    }
    SentryBootstrap.resetForTest();
    SdkLogger.onLog = null;
    XboardConfig.resetForTest();
  });

  Future<void> bootstrap({SentryReportingPreferenceStore? store}) async {
    container = ProviderContainer(
      overrides: [
        if (store != null)
          sentryReportingPreferenceStoreProvider.overrideWithValue(store),
      ],
    );
    await XboardModule.bootstrap(
      container!,
      sdk: sdk,
      tokenStorage: FakeTokenStorage(),
      config: _config,
    );
  }

  test(
    'saved opt-out is read before native initialization; client still starts',
    () async {
      SharedPreferences.setMockInitialValues({
        kSentryReportingEnabledKey: false,
      });
      await bootstrap();
      expect(runtime.initializations, 0);
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(container!.read(bootstrapReadyProvider), isTrue);
      expect(
        (await container!.read(
          sentryReportingPreferenceProvider.future,
        )).enabled,
        isFalse,
      );
    },
  );

  test(
    'preference read failure fails closed without blocking SDK startup',
    () async {
      await bootstrap(store: _FailingStore());
      expect(runtime.initializations, 0);
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(container!.read(bootstrapReadyProvider), isTrue);
      expect(
        container!.read(sentryReportingPreferenceProvider).hasError,
        isTrue,
      );
    },
  );

  test(
    'missing preference preserves default reporting through real startup wiring',
    () async {
      await bootstrap();
      expect(runtime.initializations, 1);
      expect(SentryBootstrap.isEnabled, isTrue);
      expect(runtime.options!.environment, 'brand_a');
      expect(runtime.options!.beforeSend, isNull);
      expect(container!.read(bootstrapReadyProvider), isTrue);
    },
  );

  test('early main entry and module share one native initialization', () async {
    await XboardModule.initializeMonitoringEarly(config: _config);
    expect(runtime.initializations, 1);
    expect(SentryBootstrap.isEnabled, isTrue);
    await bootstrap();
    expect(runtime.initializations, 1);
    expect(runtime.closes, 0);
    expect(container!.read(bootstrapReadyProvider), isTrue);
    expect(
      (await container!.read(sentryReportingPreferenceProvider.future)).enabled,
      isTrue,
    );
  });

  test(
    'pre-container opt-out snapshot is shared, then retry reads storage',
    () async {
      SharedPreferences.setMockInitialValues({
        kSentryReportingEnabledKey: false,
      });
      await XboardModule.initializeMonitoringEarly(config: _config);
      expect(runtime.initializations, 0);
      // Simulate the store changing between the early read and module setup.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kSentryReportingEnabledKey, true);
      await bootstrap();
      expect(runtime.initializations, 0);
      expect(
        (await container!.read(
          sentryReportingPreferenceProvider.future,
        )).enabled,
        isFalse,
      );
      container!.invalidate(sentryReportingPreferenceProvider);
      expect(
        (await container!.read(
          sentryReportingPreferenceProvider.future,
        )).enabled,
        isTrue,
      );
      expect(
        runtime.initializations,
        0,
        reason: 'a settings read never starts SDK',
      );
    },
  );

  test(
    'early preference read failure stays disabled and reaches settings once',
    () async {
      await SentryBootstrap.installForApplicationStartup(
        dsn: _config.sentryDsn,
        release: 'controlled@1+1',
        readEnabled: () async => throw StateError('early storage unavailable'),
        sharePreferenceWithSettings: true,
      );
      await bootstrap();
      expect(runtime.initializations, 0);
      expect(
        container!.read(sentryReportingPreferenceProvider).hasError,
        isTrue,
      );
      expect(container!.read(bootstrapReadyProvider), isTrue);
      container!.invalidate(sentryReportingPreferenceProvider);
      expect(
        (await container!.read(
          sentryReportingPreferenceProvider.future,
        )).enabled,
        isTrue,
      );
      expect(runtime.initializations, 0);
    },
  );

  test(
    'early native initialization failure cannot be retried by module',
    () async {
      runtime = _FailingNativeRuntime(beforeFailure: () {});
      SentryBootstrap.setRuntimeForTest(runtime);
      await XboardModule.initializeMonitoringEarly(config: _config);
      expect(SentryBootstrap.restartRequired, isTrue);
      await bootstrap();
      expect(runtime.initializations, 1);
      expect(runtime.closes, 1);
      final preference = await container!.read(
        sentryReportingPreferenceProvider.future,
      );
      expect(preference.restartRequired, isTrue);
      expect(preference.enabled, isTrue);
      expect(container!.read(bootstrapReadyProvider), isTrue);
    },
  );

  test('pending preference read cannot start Sentry early', () async {
    final decision = Completer<bool>();
    final boot = bootstrap(store: _DeferredStore(decision.future));
    await pumpEventQueue();
    expect(runtime.initializations, 0);
    expect(SentryBootstrap.isEnabled, isFalse);
    decision.complete(false);
    await boot;
    expect(runtime.initializations, 0);
    expect(container!.read(bootstrapReadyProvider), isTrue);
  });

  test(
    'partial native startup failure refreshes the already-read preference state',
    () async {
      var observedInitialPreference = false;
      runtime = _FailingNativeRuntime(
        beforeFailure: () {
          final initial = container!
              .read(sentryReportingPreferenceProvider)
              .requireValue;
          expect(initial.restartRequired, isFalse);
          observedInitialPreference = true;
        },
      );
      SentryBootstrap.setRuntimeForTest(runtime);
      await bootstrap();
      expect(observedInitialPreference, isTrue);
      expect(SentryBootstrap.restartRequired, isTrue);
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(container!.read(bootstrapReadyProvider), isTrue);
      final refreshed = await container!.read(
        sentryReportingPreferenceProvider.future,
      );
      expect(refreshed.enabled, isTrue, reason: 'saved choice is unchanged');
      expect(
        refreshed.restartRequired,
        isTrue,
        reason: 'settings must show restart immediately, before a user tap',
      );
    },
  );

  test(
    'real SDK logger bridge preserves exception and stack with console logs disabled',
    () async {
      await bootstrap();
      runtime.errors.clear();
      SdkLogger.enable(enabled: false);
      final error = StateError('controlled SDK error');
      final stack = StackTrace.current;
      SdkLogger.e('subscription fetch failed', error, stack);
      expect(runtime.errors, hasLength(1));
      final captured = runtime.errors.single;
      expect(captured.error, same(error));
      expect(captured.stackTrace, same(stack));
      expect(captured.message, 'subscription fetch failed');
      expect(captured.level, SentryLevel.error);
      SdkLogger.i('ignored SDK information', error, stack);
      expect(runtime.errors, hasLength(1));
    },
  );
}

class _TokenStorageFallback extends Fake implements TokenStorage {}

class _DeferredStore extends SentryReportingPreferenceStore {
  _DeferredStore(this.decision);
  final Future<bool> decision;

  @override
  Future<bool> readEnabled() => decision;
}

class _FailingStore extends SentryReportingPreferenceStore {
  @override
  Future<bool> readEnabled() async => throw StateError('read failed');
}

/// Never constructs a native SDK, transport, session or network client.
class _RecordingRuntime implements SentryBootstrapRuntime {
  int initializations = 0;
  int closes = 0;
  SentryFlutterOptions? options;
  final scope = Scope(SentryOptions());
  final errors =
      <
        ({
          Object error,
          StackTrace? stackTrace,
          String? message,
          SentryLevel? level,
        })
      >[];

  @override
  Future<void> initialize(void Function(SentryFlutterOptions) configure) async {
    initializations++;
    options = SentryFlutterOptions();
    configure(options!);
  }

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> configureScope(void Function(Scope) configure) async =>
      configure(scope);

  @override
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? where,
    String? message,
    SentryLevel? level,
  }) async {
    errors.add((
      error: error,
      stackTrace: stackTrace,
      message: message,
      level: level,
    ));
  }

  @override
  Future<void> captureMessage(String message, SentryLevel level) async {}
}

class _FailingNativeRuntime extends _RecordingRuntime
    implements SentryBootstrapRuntimePolicy {
  _FailingNativeRuntime({required this.beforeFailure});
  final void Function() beforeFailure;

  @override
  bool get preferenceChangesRequireRestart => true;

  @override
  Future<void> initialize(void Function(SentryFlutterOptions) configure) async {
    await super.initialize(configure);
    beforeFailure();
    throw StateError('controlled partial native initialization failure');
  }
}
