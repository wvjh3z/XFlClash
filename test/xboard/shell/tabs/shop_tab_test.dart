import 'dart:async';

import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/guest_catalog.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/tabs/shop/shop_tab.dart';
import 'package:fl_clash/xboard/shell/tabs/shop/xb_shop_navigation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Auth extends AuthStateNotifier {
  _Auth(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;

  void leave() => state = AuthState.unauthenticated;
}

class _Service extends Mock
    implements XboardService, XboardGuestCatalogControl {}

const _plans = [
  PlanItem(
    id: 4,
    name: '可续订套餐',
    transferEnableGb: 180,
    description: '<p>一</p><p>二</p><p>三</p><p>📶 第四条完整显示</p>',
    prices: [
      PricePlan(period: XbPlanPeriod.resetTraffic, amountYuan: 8),
      PricePlan(period: XbPlanPeriod.monthly, amountYuan: 25.01),
      PricePlan(period: XbPlanPeriod.yearly, amountYuan: 270.89),
    ],
  ),
  PlanItem(
    id: 9,
    name: '不限时套餐',
    transferEnableGb: 400,
    prices: [PricePlan(period: XbPlanPeriod.onetime, amountYuan: 359)],
  ),
];

XbDomainSubscription _profile({int? planId = 4, bool expired = false}) =>
    XbDomainSubscription(
      email: 'shop@example.invalid',
      uuid: 'shop-fixture',
      // A zero quota must not mask a real, valid plan ID.
      totalBytes: 0,
      usedBytes: 0,
      planId: planId,
      planName: '可续订套餐',
      expiredAt: expired
          ? DateTime.now().subtract(const Duration(days: 1))
          : null,
    );

ProviderContainer _container(
  _Service service, {
  required Future<XbDomainSubscription> Function() profile,
  AuthState auth = AuthState.authenticated,
}) {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _Auth(auth)),
      userProfileProvider.overrideWith((_) => profile()),
      xboardServiceProvider.overrideWithValue(service),
    ],
  );
  container.read(bootstrapReadyProvider.notifier).set(true);
  addTearDown(container.dispose);
  return container;
}

Widget _app(
  ProviderContainer container, {
  bool mobile = true,
  XbShopIntent? intent,
  ValueChanged<XbShopIntent>? onHandled,
  VoidCallback? onLogin,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    home: Scaffold(
      body: ShopTab(
        active: true,
        mobile: mobile,
        intent: intent,
        onIntentHandled: onHandled,
        onTapLogin: onLogin ?? () {},
      ),
    ),
  ),
);

Finder _text(String text) => find.text(text, findRichText: true);

Future<void> _tap(WidgetTester tester, String label) async {
  final target = _text(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void _noWrites(_Service service) {
  verifyNever(
    () => service.createOrder(any(), any(), couponCode: any(named: 'couponCode')),
  );
}

void main() {
  setUpAll(() => registerFallbackValue(XbPlanPeriod.monthly));

  for (final expired in [false,true]) {
    testWidgets('owned non-renewable plan cannot enter checkout (expired=$expired)', (t) async {
      final service = _Service();
      when(service.getPlans).thenAnswer((_) async => XbSuccess([_plans.first.copyWith(renewable: false), _plans.last]));
      await t.pumpWidget(_app(_container(service, profile: () async => _profile(expired: expired))));
      await t.pumpAndSettle();
      final button = find.ancestor(of: _text('当前套餐不可续费'), matching: find.byType(OutlinedButton));
      expect(t.widget<OutlinedButton>(button).onPressed, isNull);
      expect(_text('购买 不限时套餐'), findsOneWidget);
      _noWrites(service);
    });
  }
  testWidgets('six compact choices fit a 320dp shop without scrolling', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 840);
    addTearDown(t.view.reset);
    final service = _Service();
    final prices = [for (final period in XbPlanPeriod.values.take(6)) PricePlan(period: period, amountYuan: 20.0 + period.index)];
    when(service.getPlans).thenAnswer((_) async => XbSuccess([_plans.first.copyWith(prices: prices, transferEnableGb: 100, description: '<p>流量　100 GB/月</p>')]));
    await t.pumpWidget(_app(_container(service, profile: () async => _profile())));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.data_usage), findsNothing);
    expect(find.textContaining('100 GB/月', findRichText: true), findsOneWidget);
    final last = find.byKey(const ValueKey(('shop-period', 4, XbPlanPeriod.threeYearly)));
    final row = find.ancestor(of: last, matching: find.byType(SingleChildScrollView)).first;
    expect(t.getRect(last).right, lessThanOrEqualTo(t.getRect(row).right));
    expect(t.getSize(last).height, greaterThanOrEqualTo(44));
    await t.tap(last);
    await t.pumpAndSettle();
    expect(_text('¥25.00  / 三年'), findsOneWidget);
    _noWrites(service);
  });
  testWidgets('catalog shows cents, real periods and complete details', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1000, 900);
    addTearDown(t.view.reset);
    final service = _Service();
    when(service.getPlans).thenAnswer((_) async => const XbSuccess(_plans));
    final c = _container(service, profile: () async => _profile());
    await t.pumpWidget(_app(c, mobile: false));
    await t.pumpAndSettle();

    final first = find.byKey(const ValueKey('shop-plan-title-4'));
    final second = find.byKey(const ValueKey('shop-plan-title-9'));
    final yearly = find.byKey(
      const ValueKey(('shop-period', 4, XbPlanPeriod.yearly)),
    );
    expect(t.getTopLeft(first).dy, t.getTopLeft(second).dy);
    expect(t.getTopLeft(first).dy - t.getBottomLeft(_text('商店')).dy, lessThan(80));
    expect(_text('¥25.01  / 月'), findsOneWidget);
    expect(_text('¥359.00  一次性'), findsOneWidget);
    expect(find.textContaining('第四条完整显示', findRichText: true), findsWidgets);
    expect(_text('流量重置包'), findsNothing);
    expect(FocusManager.instance.primaryFocus?.context?.widget.key,
        isNot(const ValueKey('shop-plan-title-4')));

    await t.tap(yearly);
    await t.pumpAndSettle();
    expect(_text('¥270.89  / 年'), findsOneWidget);
    expect(_text('¥359.00  一次性'), findsOneWidget);
    expect(find.byType(PlanDetailPage), findsNothing);

    t.view.physicalSize = const Size(390, 900);
    await t.pumpWidget(_app(c, mobile: true));
    await t.pumpAndSettle();
    expect(t.getTopLeft(first).dy, lessThan(t.getTopLeft(second).dy));
    expect(t.getTopLeft(first).dy - t.getBottomLeft(_text('商店')).dy, lessThan(80));
    expect(t.widget<Semantics>(yearly).properties.selected, isTrue);
    verify(service.getPlans).called(1);
    _noWrites(service);
  });

  for (final scenario in ['renew', 'switch', 'expired']) {
    testWidgets('$scenario confirmation and period handoff never submit', (t) async {
      final service = _Service();
      when(service.getPlans).thenAnswer((_) async => const XbSuccess(_plans));
      final expired = scenario == 'expired';
      final c = _container(service, profile: () async => _profile(expired: expired));
      await t.pumpWidget(_app(c));
      await t.pumpAndSettle();

      final same = scenario != 'switch';
      final action = switch (scenario) {
        'renew' => '续费 可续订套餐',
        'switch' => '购买 不限时套餐',
        _ => '购买 可续订套餐',
      };
      if (same && !expired) await _tap(t, '月付');
      if (expired) await _tap(t, '年付');
      await _tap(t, action);
      if (!expired) {
        expect(find.byType(PlanDetailPage), findsNothing);
        final title = same ? '确认续费相同套餐' : '确认更换套餐';
        expect(_text(title), findsOneWidget);
        expect(
          find.textContaining(same ? '流量重置日不变' : '剩余流量和有效期不会保留', findRichText: true),
          findsOneWidget,
        );
        if (same) {
          expect(_text('当前的可续订套餐仍在有效期内。'), findsOneWidget);
          expect(_text('不会改变'), findsOneWidget);
          expect(_text('按购买周期增加'), findsOneWidget);
          expect(t.getSize(find.widgetWithText(FilledButton,'继续续费')).width,
              closeTo(t.getSize(find.widgetWithText(FilledButton,'再想想')).width, 0.1));
        }
        await _tap(t, '再想想');
        expect(_text(title), findsNothing);
        _noWrites(service);
        await _tap(t, action);
        await _tap(t, same ? '继续续费' : '确认更换');
      }
      expect(find.byType(AlertDialog), findsNothing);
      final page = t.widget<PlanDetailPage>(find.byType(PlanDetailPage));
      expect(page.renew, scenario == 'renew');
      expect(page.plan.id, same ? 4 : 9);
      expect(page.initialPeriod, scenario == 'renew' ? isNull : equals(same ? XbPlanPeriod.yearly : XbPlanPeriod.onetime));
      expect(page.confirmedFor, expired ? null : 4);
      Navigator.of(t.element(find.byType(PlanDetailPage))).pop();
      await t.pumpAndSettle();
      expect(find.ancestor(of: _text(action), matching: find.byType(FilledButton)), findsOneWidget);
      _noWrites(service);
    });
  }

  testWidgets('intent waits for profile; downlisted intent returns to top', (t) async {
    final service = _Service();
    when(service.getPlans).thenAnswer((_) async => const XbSuccess(_plans));
    final response = Completer<XbDomainSubscription>();
    final c = _container(service, profile: () => response.future);
    final handled = <XbShopIntent>[];
    const intent = XbShopIntent(
      authenticated: true,
      revision: 0,
      planId: null,
      waitForProfile: true,
    );
    await t.pumpWidget(_app(c, intent: intent, onHandled: handled.add));
    await t.pumpAndSettle();
    expect(handled, isEmpty);
    response.complete(_profile(planId: 9, expired: true));
    await t.pumpAndSettle();
    expect(handled, [intent]);
    expect(FocusManager.instance.primaryFocus?.context?.widget.key,
        const ValueKey('shop-plan-title-9'));

    const downlisted = XbShopIntent(
      authenticated: true,
      revision: 0,
      planId: 33,
      waitForProfile: false,
    );
    await t.pumpWidget(_app(c, intent: downlisted, onHandled: handled.add));
    await t.pumpAndSettle();
    expect(handled, [intent, downlisted]);
    expect(FocusManager.instance.primaryFocus?.context?.widget.key,
        isNot(const ValueKey('shop-plan-title-9')));
    expect(find.byType(PlanDetailPage), findsNothing);
    _noWrites(service);
  });

  testWidgets('guest browses public prices; tapping only requests login', (t) async {
    final service = _Service();
    final reply = Completer<XbResult<List<PlanItem>>>();
    when(service.getPlans).thenAnswer((_) => reply.future);
    when(service.getGuestCatalog).thenAnswer(
      (_) async => XbSuccess([
        _plans.last.copyWith(id: 12, name: '真实公开套餐'),
      ]),
    );
    var profileReads = 0;
    final c = _container(
      service,
      auth: AuthState.unauthenticated,
      profile: () async {
        profileReads++;
        return _profile();
      },
    );
    var login = 0;
    await t.pumpWidget(_app(c, onLogin: () => login++));
    await t.pumpAndSettle();
    expect(_text('真实公开套餐'), findsOneWidget);
    expect(_text('¥359.00  一次性'), findsOneWidget);
    expect(find.byType(PlanDetailPage), findsNothing);
    verify(service.getGuestCatalog).called(1);
    verifyNever(service.getPlans);
    expect(profileReads, 0);
    final buy = _text('购买 真实公开套餐');
    final outline = find.ancestor(of: buy, matching: find.byType(OutlinedButton));
    expect(t.widget<OutlinedButton>(outline).style!.foregroundColor!.resolve({}), const Color(0xFF365A73));
    await _tap(t, '购买 真实公开套餐');
    expect(login, 1);
    expect(find.ancestor(of: buy, matching: find.byType(FilledButton)), findsOneWidget);
    expect(find.byType(PlanDetailPage), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    final auth = c.read(authStateProvider.notifier) as _Auth;
    auth.markAuthenticated();
    await t.pump();
    verify(service.getPlans).called(1);
    auth.leave();
    await t.pump();
    reply.complete(const XbSuccess(_plans));
    await t.pumpAndSettle();
    expect(_text('真实公开套餐'), findsOneWidget);
    expect(_text('可续订套餐'), findsNothing);
    _noWrites(service);
  });
}
