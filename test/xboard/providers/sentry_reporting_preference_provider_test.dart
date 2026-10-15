import 'dart:async';

import 'package:fl_clash/xboard/providers/sentry_reporting_preference_provider.dart';
import 'package:fl_clash/xboard/services/sentry_reporting_preference.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeReportingStore extends SentryReportingPreferenceStore {
  bool enabled = true;
  bool failRead = false;
  bool failWrite = false;
  int writes = 0;
  Completer<void>? writeGate;

  @override
  Future<bool> readEnabled() async {
    if (failRead) throw StateError('read failed');
    return enabled;
  }

  @override
  Future<void> writeEnabled(bool value) async {
    writes++;
    if (writeGate != null) await writeGate!.future;
    if (failWrite) throw StateError('write failed');
    enabled = value;
  }
}

void main() {
  late FakeReportingStore store;
  late List<bool> appliedOptOut;
  late bool runtimeFails;
  late bool restartRequired;
  late bool requiresRestartOnChange;

  ProviderContainer container({bool configured = true}) {
    final result = ProviderContainer(
      overrides: [
        sentryReportingPreferenceStoreProvider.overrideWithValue(store),
        sentryReportingConfiguredProvider.overrideWithValue(configured),
        sentryReportingRestartRequiredProvider.overrideWithValue(
          () => restartRequired,
        ),
        sentryReportingApplyOptOutProvider.overrideWithValue((value) async {
          appliedOptOut.add(value);
          if (requiresRestartOnChange) {
            restartRequired = true;
            throw const SentryRestartRequiredException();
          }
          if (runtimeFails) throw StateError('native state unknown');
        }),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  setUp(() {
    store = FakeReportingStore();
    appliedOptOut = [];
    runtimeFails = false;
    restartRequired = false;
    requiresRestartOnChange = false;
  });

  test('startup consumes saved opt-out without initializing Sentry', () async {
    store.enabled = false;
    final c = container();
    expect(
      (await c.read(sentryReportingPreferenceProvider.future)).enabled,
      isFalse,
    );
    expect(appliedOptOut, isEmpty);
    expect(store.writes, 0);
  });

  test(
    'disable and re-enable await runtime and persist across a new container',
    () async {
      final c = container();
      await c.read(sentryReportingPreferenceProvider.future);
      final notifier = c.read(sentryReportingPreferenceProvider.notifier);
      expect(
        await notifier.setEnabled(false),
        SentryReportingChangeResult.success,
      );
      expect(store.enabled, isFalse);
      expect(appliedOptOut, [true]);
      final restarted = container();
      expect(
        (await restarted.read(
          sentryReportingPreferenceProvider.future,
        )).enabled,
        isFalse,
      );
      expect(
        await notifier.setEnabled(true),
        SentryReportingChangeResult.success,
      );
      expect(store.enabled, isTrue);
      expect(appliedOptOut, [true, false]);
    },
  );

  test(
    'failed persistence does not change saved choice or call native runtime',
    () async {
      store.failWrite = true;
      final c = container();
      await c.read(sentryReportingPreferenceProvider.future);
      final result = await c
          .read(sentryReportingPreferenceProvider.notifier)
          .setEnabled(false);
      expect(result, SentryReportingChangeResult.persistenceFailed);
      final state = c.read(sentryReportingPreferenceProvider).requireValue;
      expect(state.enabled, isTrue);
      expect(state.isSaving, isFalse);
      expect(appliedOptOut, isEmpty);
    },
  );

  test(
    'overlapping toggles cannot race persistence or native initialization',
    () async {
      store.writeGate = Completer<void>();
      final c = container();
      await c.read(sentryReportingPreferenceProvider.future);
      final notifier = c.read(sentryReportingPreferenceProvider.notifier);
      final first = notifier.setEnabled(false);
      expect(
        c.read(sentryReportingPreferenceProvider).requireValue.isSaving,
        isTrue,
      );
      expect(await notifier.setEnabled(true), SentryReportingChangeResult.busy);
      expect(store.writes, 1);
      store.writeGate!.complete();
      expect(await first, SentryReportingChangeResult.success);
      expect(appliedOptOut, [true]);
      expect(store.enabled, isFalse);
    },
  );

  test(
    'native failure preserves saved preference and same-value retry is allowed',
    () async {
      runtimeFails = true;
      final c = container();
      await c.read(sentryReportingPreferenceProvider.future);
      final notifier = c.read(sentryReportingPreferenceProvider.notifier);
      expect(
        await notifier.setEnabled(false),
        SentryReportingChangeResult.runtimeFailed,
      );
      expect(store.enabled, isFalse);
      expect(
        c.read(sentryReportingPreferenceProvider).requireValue.runtimeFailed,
        isTrue,
      );
      runtimeFails = false;
      expect(
        await notifier.setEnabled(false),
        SentryReportingChangeResult.success,
      );
      expect(
        c.read(sentryReportingPreferenceProvider).requireValue.runtimeFailed,
        isFalse,
      );
      expect(appliedOptOut, [true, true]);
    },
  );

  test('missing DSN disables changes without erasing saved choice', () async {
    final c = container(configured: false);
    final initial = await c.read(sentryReportingPreferenceProvider.future);
    expect(initial.configured, isFalse);
    expect(initial.enabled, isTrue);
    expect(
      await c
          .read(sentryReportingPreferenceProvider.notifier)
          .setEnabled(false),
      SentryReportingChangeResult.unavailable,
    );
    expect(store.writes, 0);
    expect(appliedOptOut, isEmpty);
  });

  test(
    'read failure stays explicit; retry may forcibly apply startup-skipped choice',
    () async {
      store.failRead = true;
      final c = container();
      await expectLater(
        c.read(sentryReportingPreferenceProvider.future),
        throwsStateError,
      );
      expect(c.read(sentryReportingPreferenceProvider).hasError, isTrue);
      store.failRead = false;
      c.invalidate(sentryReportingPreferenceProvider);
      await c.read(sentryReportingPreferenceProvider.future);
      expect(
        await c
            .read(sentryReportingPreferenceProvider.notifier)
            .setEnabled(true, force: true),
        SentryReportingChangeResult.success,
      );
      expect(appliedOptOut, [false]);
    },
  );

  test(
    'native changes save choice and require restart without claiming failure',
    () async {
      requiresRestartOnChange = true;
      final c = container();
      await c.read(sentryReportingPreferenceProvider.future);
      final notifier = c.read(sentryReportingPreferenceProvider.notifier);
      expect(
        await notifier.setEnabled(false),
        SentryReportingChangeResult.restartRequired,
      );
      expect(store.enabled, isFalse);
      final changed = c.read(sentryReportingPreferenceProvider).requireValue;
      expect(changed.restartRequired, isTrue);
      expect(changed.runtimeFailed, isFalse);
      expect(
        await notifier.setEnabled(true),
        SentryReportingChangeResult.restartRequired,
      );
      expect(store.writes, 1);
      expect(appliedOptOut, [true]);
      c.invalidate(sentryReportingPreferenceProvider);
      final reloaded = await c.read(sentryReportingPreferenceProvider.future);
      expect(reloaded.restartRequired, isTrue);
      expect(reloaded.enabled, isFalse);
      expect(
        await c
            .read(sentryReportingPreferenceProvider.notifier)
            .setEnabled(true),
        SentryReportingChangeResult.restartRequired,
      );
      expect(store.writes, 1);
    },
  );
}
