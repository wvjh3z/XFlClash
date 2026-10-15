import 'dart:async';

import 'package:fl_clash/xboard/providers/sentry_reporting_preference_provider.dart';
import 'package:fl_clash/xboard/services/sentry_reporting_preference.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/xb_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSettingsReportingStore extends SentryReportingPreferenceStore {
  bool enabled = true;
  bool failRead = false;
  bool failWrite = false;
  Completer<void>? writeGate;

  @override
  Future<bool> readEnabled() async {
    if (failRead) throw StateError('read failure');
    return enabled;
  }

  @override
  Future<void> writeEnabled(bool value) async {
    await writeGate?.future;
    if (failWrite) throw StateError('write failure');
    enabled = value;
  }
}

void main() {
  late FakeSettingsReportingStore store;
  late List<bool> appliedOptOut;
  late bool runtimeFails;
  late bool requiresRestart;
  late bool restartPending;

  setUp(() {
    store = FakeSettingsReportingStore();
    appliedOptOut = [];
    runtimeFails = false;
    requiresRestart = false;
    restartPending = false;
  });

  Future<void> showSettings(
    WidgetTester tester, {
    bool configured = true,
    bool embedded = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sentryReportingPreferenceStoreProvider.overrideWithValue(store),
          sentryReportingConfiguredProvider.overrideWithValue(configured),
          sentryReportingRestartRequiredProvider.overrideWithValue(
            () => restartPending,
          ),
          sentryReportingApplyOptOutProvider.overrideWithValue((value) async {
            appliedOptOut.add(value);
            if (requiresRestart) {
              restartPending = true;
              throw const SentryRestartRequiredException();
            }
            if (runtimeFails) throw StateError('native failure');
          }),
        ],
        child: MaterialApp(
          home: embedded
              ? const Scaffold(body: XbSettingsPage(embedded: true))
              : const XbSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final reportingSwitch = find.byKey(const ValueKey('sentry-reporting-switch'));

  testWidgets('settings exposes an operable persisted reporting choice', (
    tester,
  ) async {
    await showSettings(tester);
    expect(find.text('隐私'), findsOneWidget);
    expect(find.text('崩溃信息上报'), findsOneWidget);
    expect(tester.widget<Switch>(reportingSwitch).value, isTrue);
    await tester.tap(reportingSwitch);
    await tester.pumpAndSettle();
    expect(store.enabled, isFalse);
    expect(tester.widget<Switch>(reportingSwitch).value, isFalse);
    expect(appliedOptOut, [true]);
    expect(find.text('已关闭崩溃信息上报'), findsOneWidget);
  });

  testWidgets('desktop embedded settings shares the same reporting control', (
    tester,
  ) async {
    store.enabled = false;
    await showSettings(tester, embedded: true);
    expect(tester.widget<Switch>(reportingSwitch).value, isFalse);
    await tester.tap(reportingSwitch);
    await tester.pumpAndSettle();
    expect(store.enabled, isTrue);
    expect(appliedOptOut, [false]);
  });

  testWidgets(
    'missing DSN visibly disables control without erasing preference',
    (tester) async {
      await showSettings(tester, configured: false);
      final widget = tester.widget<Switch>(reportingSwitch);
      expect(widget.value, isFalse);
      expect(widget.onChanged, isNull);
      expect(find.text('当前版本未配置崩溃信息上报'), findsOneWidget);
      expect(store.enabled, isTrue);
      expect(appliedOptOut, isEmpty);
    },
  );

  testWidgets('persistence failure keeps original switch and shows feedback', (
    tester,
  ) async {
    store.failWrite = true;
    await showSettings(tester);
    await tester.tap(reportingSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(reportingSwitch).value, isTrue);
    expect(find.text('设置保存失败，请重试'), findsOneWidget);
    expect(appliedOptOut, isEmpty);
  });

  testWidgets(
    'read failure is retryable and applies a startup-skipped choice',
    (tester) async {
      store.failRead = true;
      await showSettings(tester);
      expect(tester.widget<Switch>(reportingSwitch).onChanged, isNull);
      expect(find.text('读取设置失败，点击重试'), findsOneWidget);
      store.failRead = false;
      await tester.tap(find.text('崩溃信息上报'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(reportingSwitch).value, isTrue);
      expect(tester.widget<Switch>(reportingSwitch).onChanged, isNotNull);
      expect(appliedOptOut, [false]);
    },
  );

  testWidgets(
    'native failure describes saved preference and allows same-choice retry',
    (tester) async {
      runtimeFails = true;
      await showSettings(tester);
      await tester.tap(reportingSwitch);
      await tester.pumpAndSettle();
      expect(store.enabled, isFalse);
      expect(find.text('偏好已保存，当前状态同步失败；点击重试或重启应用'), findsOneWidget);
      runtimeFails = false;
      await tester.tap(find.text('崩溃信息上报'));
      await tester.pumpAndSettle();
      expect(appliedOptOut, [true, true]);
      expect(find.text('偏好已保存，当前状态同步失败；点击重试或重启应用'), findsNothing);
    },
  );

  testWidgets('pending storage write disables repeated toggles', (
    tester,
  ) async {
    store.writeGate = Completer<void>();
    await showSettings(tester);
    await tester.tap(reportingSwitch);
    await tester.pump();
    expect(tester.widget<Switch>(reportingSwitch).onChanged, isNull);
    expect(find.text('正在保存设置…'), findsOneWidget);
    store.writeGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(reportingSwitch).onChanged, isNotNull);
    expect(appliedOptOut, [true]);
  });

  testWidgets(
    'native change explains required restart and disables further toggles',
    (tester) async {
      requiresRestart = true;
      await showSettings(tester);
      await tester.tap(reportingSwitch);
      await tester.pumpAndSettle();
      final widget = tester.widget<Switch>(reportingSwitch);
      expect(widget.value, isFalse);
      expect(widget.onChanged, isNull);
      expect(store.enabled, isFalse);
      expect(find.text('偏好已保存，重启应用后生效；请完全退出后重新打开应用'), findsOneWidget);
      expect(find.text('偏好已保存，重启应用后生效'), findsOneWidget);
      expect(find.text('已关闭崩溃信息上报'), findsNothing);
      expect(find.textContaining('同步失败'), findsNothing);
      await tester.tap(find.text('崩溃信息上报'));
      await tester.pumpAndSettle();
      expect(appliedOptOut, [true]);
    },
  );
}
