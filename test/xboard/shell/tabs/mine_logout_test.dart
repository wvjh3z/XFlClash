/// Real MineTab/auth lifecycle with controlled local cleanup, without native I/O.
library;

import 'dart:async';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/invite_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Subscriptions extends Mock implements XboardSubscriptionService {}

class _Service extends Mock implements XboardService, XboardSessionLifecycle {
  int endings = 0;
  String? endedOwner;
  bool failCleanup = false;

  @override
  void invalidateSessionRequests() {}

  @override
  Future<void> endSession({
    required String? ownerHash,
    required int? sdkRevision,
    required bool expired,
  }) async {
    endings++;
    endedOwner = ownerHash;
    if (failCleanup) throw StateError('controlled credential cleanup failure');
  }
}

class _Fixture {
  final service = _Service();
  final subscriptions = _Subscriptions();
  final root = GlobalKey<NavigatorState>();
  final nested = GlobalKey<NavigatorState>();
  final cleanedOwners = <String>[];
  final gate = Completer<void>();
  late final ProviderContainer container;
  bool delayed = true;
  bool failProfiles = false;
  int loginTaps = 0;

  AuthStateNotifier get auth => container.read(authStateProvider.notifier);

  void finishCleanup() {
    if (!gate.isCompleted) gate.complete();
  }
}

Future<_Fixture> _pumpMine(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  bool delayed = true,
  bool failCleanup = false,
  bool nested = false,
  ThemeData? mineTheme,
}) async {
  final f = _Fixture()
    ..delayed = delayed
    ..failProfiles = failCleanup;
  f.service.failCleanup = failCleanup;
  when(() => f.subscriptions.clearForSessionOwner(any())).thenAnswer((
    call,
  ) async {
    f.cleanedOwners.add(call.positionalArguments.single as String);
    if (f.delayed) await f.gate.future;
    if (f.failProfiles) throw StateError('controlled profile cleanup failure');
  });
  final mobile = platform == TargetPlatform.android;
  tester.view.physicalSize = Size(mobile ? 390 : 1280, 1100);
  tester.view.devicePixelRatio = 1;
  XboardConfig.bind(
    const XboardConfig(
      subscribeUserAgent: 'logout-test',
      devApiEndpoint: 'https://example.invalid',
      devSubscriptionEndpoint: 'https://example.invalid',
      debug: false,
      kIsTest: true,
      formA: true,
    ),
  );
  f.container = ProviderContainer(
    overrides: [
      xboardServiceProvider.overrideWithValue(f.service),
      subscriptionServiceProvider.overrideWithValue(f.subscriptions),
      userProfileProvider.overrideWith(
        (ref) async => const XbDomainSubscription(
          email: 'fixture@example.invalid',
          uuid: 'fixture',
          planName: '测试套餐',
          totalBytes: 1000,
          usedBytes: 10,
          planId: 1,
        ),
      ),
      inviteInfoProvider.overrideWith(
        (ref) async => const XbInviteInfo(
          code: 'fixture',
          registeredCount: 0,
          pendingYuan: 0,
          totalYuan: 0,
          commissionRate: 0,
          commissionBalanceYuan: 0,
          accountBalanceYuan: 0,
        ),
      ),
    ],
  );
  expect(await f.auth.completeAuthentication(token: 'fixture-token'), isTrue);
  addTearDown(() async {
    f.finishCleanup();
    await tester.pumpWidget(const SizedBox.shrink());
    await f.auth.waitForSessionCleanup();
    f.container.dispose();
    XboardConfig.resetForTest();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final page = Scaffold(body: MineTab(onTapLogin: () => f.loginTaps++));
  final themedPage = mineTheme == null
      ? page
      : Theme(data: mineTheme, child: page);
  final home = nested
      ? Navigator(
          key: f.nested,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => themedPage),
        )
      : themedPage;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.container,
      child: MaterialApp(
        navigatorKey: f.root,
        theme: ThemeData(platform: platform),
        home: home,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 850));
  return f;
}

Future<BuildContext> _openConfirmation(WidgetTester tester) async {
  final logout = find.text('退出登录');
  await tester.ensureVisible(logout);
  final oldContext = tester.element(logout);
  await tester.tap(logout);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(AlertDialog), findsOneWidget);
  return oldContext;
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, '退出登录'),
    ),
  );
}

Future<void> _pumpTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
}

Future<void> _expectGuestWithoutBlocker(WidgetTester tester, _Fixture f) async {
  expect(f.container.read(authStateProvider), AuthState.unauthenticated);
  expect(find.text('未登录'), findsOneWidget);
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(f.root.currentState!.canPop(), isFalse);
  expect(f.service.endings, 1);
  expect(f.service.endedOwner, userIdHashFromToken('fixture-token'));
  expect(f.cleanedOwners, [userIdHashFromToken('fixture-token')]);
  // A MaterialPageRoute may retain an inert barrier. The actual guarantee is
  // that the guest can interact with the page after logout completes.
  final login = find.text('登录 / 注册');
  await tester.ensureVisible(login);
  final before = f.loginTaps;
  await tester.tap(login);
  await tester.pump();
  expect(f.loginTaps, before + 1);
  expect(tester.takeException(), isNull);
}

void main() {
  // Platform themes and narrow/wide layouts exercise shared Flutter behavior;
  // these cases do not claim native device, VPN or platform-storage coverage.
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '${platform.name}: logout closes its overlay after the old UI unmounts',
      (tester) async {
        final f = await _pumpMine(tester, platform: platform);
        final oldContext = await _openConfirmation(tester);
        await _confirm(tester);
        await _pumpTransition(tester);
        expect(oldContext.mounted, isFalse);
        expect(f.container.read(authStateProvider), AuthState.unauthenticated);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        var cleaned = false;
        f.auth.waitForSessionCleanup().then((_) => cleaned = true);
        await tester.pump(const Duration(seconds: 1));
        expect(cleaned, isFalse);
        f.finishCleanup();
        await _pumpTransition(tester);
        expect(cleaned, isTrue);
        await _expectGuestWithoutBlocker(tester, f);
      },
    );
  }

  testWidgets('immediate cleanup closes an overlay before its first frame', (
    tester,
  ) async {
    final f = await _pumpMine(tester, delayed: false);
    await _openConfirmation(tester);
    await _confirm(tester);
    await _pumpTransition(tester);
    await _expectGuestWithoutBlocker(tester, f);
  });

  testWidgets(
    'root dialogs retain the local dark brand theme and painted scrim',
    (tester) async {
      const scrim = Color(0xB3123456);
      final f = await _pumpMine(
        tester,
        platform: TargetPlatform.windows,
        mineTheme: ThemeData(
          platform: TargetPlatform.windows,
          brightness: Brightness.dark,
          dialogTheme: const DialogThemeData(barrierColor: scrim),
        ),
      );
      final brand = Color(XboardConfig.current.brandColor);
      expect(Theme.of(f.root.currentContext!).brightness, Brightness.light);

      void expectPaintedScrim() {
        final paintedScrim = find.byWidgetPredicate(
          (widget) => widget is ColoredBox && widget.color == scrim,
        );
        expect(paintedScrim, findsOneWidget);
        expect(tester.renderObject(paintedScrim), paints..rect(color: scrim));
      }

      await _openConfirmation(tester);
      final confirmation = find.byType(AlertDialog);
      final confirmationTheme = Theme.of(tester.element(confirmation));
      expect(confirmationTheme.brightness, Brightness.dark);
      expect(confirmationTheme.colorScheme.primary, brand);
      final dialogMaterial = find.descendant(
        of: confirmation,
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.type == MaterialType.card,
        ),
      );
      expect(tester.widget<Material>(dialogMaterial).color, XbTokens.dark.sf2);
      expectPaintedScrim();

      await _confirm(tester);
      await _pumpTransition(tester);
      final spinner = find.byType(CircularProgressIndicator);
      final spinnerTheme = Theme.of(tester.element(spinner));
      expect(spinnerTheme.brightness, Brightness.dark);
      expect(spinnerTheme.colorScheme.primary, brand);
      expectPaintedScrim();
      f.finishCleanup();
      await _pumpTransition(tester);
      await _expectGuestWithoutBlocker(tester, f);
    },
  );

  testWidgets('local cleanup errors still close the logout overlay', (
    tester,
  ) async {
    final f = await _pumpMine(tester, failCleanup: true);
    await _openConfirmation(tester);
    await _confirm(tester);
    await _pumpTransition(tester);
    f.finishCleanup();
    await _pumpTransition(tester);
    await _expectGuestWithoutBlocker(tester, f);
  });

  testWidgets(
    'cancel confirmation preserves the session without starting cleanup',
    (tester) async {
      final f = await _pumpMine(tester);
      await _openConfirmation(tester);
      await tester.tap(find.widgetWithText(FilledButton, '取消'));
      await _pumpTransition(tester);
      expect(f.container.read(authStateProvider), AuthState.authenticated);
      expect(f.service.endings, 0);
      expect(f.cleanedOwners, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(f.root.currentState!.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('logout inside a nested navigator closes only its root overlay', (
    tester,
  ) async {
    final f = await _pumpMine(tester, nested: true);
    await _openConfirmation(tester);
    await _confirm(tester);
    await _pumpTransition(tester);
    expect(f.root.currentState!.canPop(), isTrue);
    expect(f.nested.currentState!.canPop(), isFalse);
    f.finishCleanup();
    await _pumpTransition(tester);
    await _expectGuestWithoutBlocker(tester, f);
    expect(f.nested.currentState!.canPop(), isFalse);
  });

  testWidgets('a newer dialog stays open when logout cleanup finishes', (
    tester,
  ) async {
    final f = await _pumpMine(tester);
    await _openConfirmation(tester);
    await _confirm(tester);
    await _pumpTransition(tester);
    unawaited(
      showDialog<void>(
        context: f.root.currentContext!,
        builder: (_) => const AlertDialog(content: Text('保留这条提示')),
      ),
    );
    await _pumpTransition(tester);
    f.finishCleanup();
    await _pumpTransition(tester);
    expect(find.text('保留这条提示'), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator, skipOffstage: false),
      findsNothing,
    );
    expect(f.root.currentState!.canPop(), isTrue);
    f.root.currentState!.pop();
    await _pumpTransition(tester);
    await _expectGuestWithoutBlocker(tester, f);
  });

  testWidgets(
    'cleanup after the overlay already closed preserves a newer page',
    (tester) async {
      final f = await _pumpMine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);
      await _pumpTransition(tester);
      f.root.currentState!.pop();
      await _pumpTransition(tester);
      unawaited(
        f.root.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('后来的页面')),
          ),
        ),
      );
      await _pumpTransition(tester);
      f.finishCleanup();
      await _pumpTransition(tester);
      expect(find.text('后来的页面'), findsOneWidget);
      expect(
        find.byType(CircularProgressIndicator, skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      f.root.currentState!.pop();
      await _pumpTransition(tester);
      await _expectGuestWithoutBlocker(tester, f);
    },
  );

  testWidgets(
    'late cleanup after navigator disposal does not access disposed UI',
    (tester) async {
      final f = await _pumpMine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);
      await _pumpTransition(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(f.root.currentState, isNull);
      f.finishCleanup();
      await _pumpTransition(tester);
      await f.auth.waitForSessionCleanup();
      expect(f.service.endings, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
