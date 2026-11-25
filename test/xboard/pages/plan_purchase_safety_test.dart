import 'package:fl_clash/xboard/models/plan_item.dart';
import 'dart:async';
import 'package:flutter_html/flutter_html.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/confirmed_order.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_plan_details.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart';

class _Service extends Mock
    implements XboardService, XboardProgressOrderControl {
  int submitCalls = 0;
  ConfirmedOrderQuote? submittedQuote;
  bool askAboutOldOrder = false;
  bool? acceptedOldOrder;
  bool replacing = false;
  Future<void>? submitGate;
  Future<void>? createGate;
  Future<void>? verifyGate;

  @override
  Future<XbResult<String?>> confirmOrder(
    ConfirmedOrderQuote quote, {
    required bool Function() isActive,
    required Future<bool> Function(ConfirmedOrderConflict) confirm,
    void Function(ConfirmedOrderStage stage)? onStage,
  }) async {
    submitCalls++;
    submittedQuote = quote;
    onStage?.call(ConfirmedOrderStage.checking);
    if (submitGate != null) await submitGate;
    if (createGate != null && isActive()) {
      onStage?.call(ConfirmedOrderStage.creating);
      await createGate;
      onStage?.call(ConfirmedOrderStage.verifying);
      await verifyGate;
    }
    if (askAboutOldOrder) {
      acceptedOldOrder = await confirm(
        ConfirmedOrderConflict(
          sameSelection: !replacing,
          quote: quote,
          existingTradeNo: 'OLD',
          existingPlanName: replacing ? '旧套餐' : quote.planName,
          existingPeriod: quote.period,
          existingPayableCents: 2500,
        ),
      );
    }
    return const XbSuccess(null);
  }
}

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

const _plan = PlanItem(
  id: 7,
  name: '测试套餐',
  transferEnableGb: 10,
  prices: [
    PricePlan(period: XbPlanPeriod.monthly, amountYuan: 10),
    PricePlan(period: XbPlanPeriod.yearly, amountYuan: 100),
  ],
);
const _coupon = CouponInfo(code: 'VALID', type: 1, value: 100);

void main() {
  setUpAll(() => registerFallbackValue(XbPlanPeriod.monthly));
  testWidgets('narrow checkout shows text-only progress and cannot double-submit', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 844);
    addTearDown(t.view.reset);
    final read = Completer<XbResult<XbDomainSubscription>>();
    final write = Completer<void>();
    final verify = Completer<void>();
    final check = Completer<void>();
    final service = _Service()..submitGate = check.future..createGate = write.future..verifyGate = verify.future;
    when(service.getSubscription).thenAnswer((_) => read.future);
    await t.pumpWidget(ProviderScope(overrides: [
      authStateProvider.overrideWith(_Auth.new), xboardServiceProvider.overrideWithValue(service),
    ], child: MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)), child: child!),
      home: const PlanDetailPage(plan: _plan, initialPeriod: XbPlanPeriod.monthly),
    )));
    await t.pumpAndSettle();
    final start = find.widgetWithText(FilledButton, '提交订单');
    await t.ensureVisible(start);
    await t.tap(start);
    await t.pump();
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '正在核对当前套餐…')).onPressed, isNull);
    read.complete(const XbSuccess(XbDomainSubscription(email:'f@example.invalid',uuid:'fixture',totalBytes:0,usedBytes:0)));
    await t.pump();
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '正在核对订单…')).onPressed, isNull);
    expect(find.text('正在创建订单…'), findsNothing);
    check.complete();
    await t.pump();
    final busy = find.widgetWithText(FilledButton, '正在创建订单…');
    expect(t.widget<FilledButton>(busy).onPressed, isNull);
    expect(find.descendant(of: busy, matching: find.byType(CircularProgressIndicator)), findsNothing);
    final text = t.renderObject<RenderParagraph>(find.text('正在创建订单…'));
    expect(text.text.style?.color, Colors.white);
    expect(text.textAlign, TextAlign.center);
    await t.tap(busy);
    await t.pump();
    expect(service.submitCalls, 1);
    expect(t.takeException(), isNull);
    write.complete();
    await t.pump();
    expect(find.text('正在核实下单结果…'), findsNothing);
    expect(t.widget<FilledButton>(busy).onPressed, isNull);
    expect(service.submitCalls, 1);
    verify.complete();
    await t.pumpAndSettle();
    expect(t.widget<FilledButton>(start).onPressed, isNotNull);
  });
  for (final width in [360.0, 1280.0]) {
    testWidgets('checkout $width preserves period, layout and acknowledgement', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1100);
      addTearDown(tester.view.reset);
      XboardConfig.bind(const XboardConfig(
        appName: 'Fixture',
        flavorId: 'brand_a',
        subscribeUserAgent: 'fixture',
        devApiEndpoint: '',
        devSubscriptionEndpoint: '',
        debug: true,
        kIsTest: true,
        formA: true,
      ));
      addTearDown(XboardConfig.resetForTest);
      final service = _Service()..askAboutOldOrder = true;
      when(service.getSubscription).thenAnswer((_) async => const XbSuccess(
        XbDomainSubscription(
          email: 'fixture@example.test',
          uuid: 'fixture',
          totalBytes: 100,
          usedBytes: 0,
          planId: 3,
        ),
      ));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          xboardServiceProvider.overrideWithValue(service),
          authStateProvider.overrideWith(_Auth.new),
        ],
        child: const MaterialApp(
          home: PlanDetailPage(
            plan: _plan,
            initialPeriod: XbPlanPeriod.monthly,
            confirmedFor: 3,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(FilledButton, '提交订单');
      final form = find.byType(TextField);
      expect(tester.getTopLeft(form).dy, greaterThan(tester.getTopLeft(button).dy));
      expect(find.widgetWithText(AppBar, width < 840 ? _plan.name : '购买套餐'), findsOneWidget);
      expect(find.text(_plan.name, findRichText: true), findsNWidgets(width < 840 ? 2 : 1));
      expect(find.textContaining('10 GB', findRichText: true), findsNothing);
      expect(find.byType(Html), findsNothing);
      expect(find.text('订单摘要'), findsNothing);
      expect(find.text('省 17%'), findsOneWidget);

      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(service.submitCalls, 1);
      expect(service.submittedQuote!.period, XbPlanPeriod.monthly);
      expect(service.submittedQuote!.estimatedCents, 1000);
      expect(find.text('确认更换套餐'), findsNothing);
      expect(find.text('月付 · ¥10.00'), findsOneWidget);
      final replaceExisting = find.text('取消旧单并下单');
      expect(find.text('本次套餐和周期与原订单相同。'), findsOneWidget);
      expect(replaceExisting, findsOneWidget);
      await tester.tap(replaceExisting);
      await tester.pumpAndSettle();
      expect(service.acceptedOldOrder, isTrue);
      service.replacing = true;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('旧套餐'), findsOneWidget);
      expect(find.text('本次下单'), findsOneWidget);
      expect(find.text('取消旧单并下单'), findsOneWidget);
      await tester.tap(find.text('再想想'));
      await tester.pumpAndSettle();
      expect(service.acceptedOldOrder, isFalse);
      verifyNever(() => service.createOrder(any(), any(), couponCode: any(named: 'couponCode')));
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('mobile checkout aligns actions and coupon in $brightness', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 860);
      addTearDown(tester.view.reset);
      final dark = brightness == Brightness.dark;
      XboardConfig.bind(
        XboardConfig(
          appName: 'Fixture',
          flavorId: dark ? 'brand_b' : 'brand_a',
          brandColor: dark ? 0xFF245BA9 : 0xFFD92E1A,
          subscribeUserAgent: 'fixture',
          devApiEndpoint: '',
          devSubscriptionEndpoint: '',
          debug: true,
          kIsTest: true,
          formA: true,
        ),
      );
      addTearDown(XboardConfig.resetForTest);
      final service = _Service();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            xboardServiceProvider.overrideWithValue(service),
            authStateProvider.overrideWith(_Auth.new),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(dark ? 2 : 1),
              ),
              child: child!,
            ),
            home: const PlanDetailPage(
              plan: _plan,
              initialPeriod: XbPlanPeriod.monthly,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final back = find.widgetWithText(OutlinedButton, '返回');
      final submit = find.widgetWithText(FilledButton, '提交订单');
      final tokens = XbTokens.of(tester.element(back));
      expect(
        tester.widget<OutlinedButton>(back).style!.backgroundColor!.resolve({}),
        Colors.transparent,
      );
      expect(tester.widget<OutlinedButton>(back).style!.side!.resolve({})!.color, isNot(tokens.line));
      expect(tester.getSize(back).width, 72);
      expect(tester.getSize(back).height, tester.getSize(submit).height);
      expect(
        tester.renderObject<RenderParagraph>(find.text('提交订单')).text.style?.color,
        Colors.white,
      );
      final gradient = find.ancestor(
        of: submit,
        matching: find.byWidgetPredicate((widget) {
          if (widget is! DecoratedBox) return false;
          final decoration = widget.decoration;
          return decoration is BoxDecoration && decoration.gradient is LinearGradient;
        }),
      );
      expect(gradient, findsOneWidget);
      final field = find.byType(TextField);
      final surface = find.byKey(const ValueKey('coupon-input-surface'));
      final verify = find.widgetWithText(OutlinedButton, '验证');
      expect(tester.getTopLeft(field).dy, greaterThan(tester.getBottomLeft(submit).dy));
      expect(tester.getTopLeft(surface).dy, closeTo(tester.getTopLeft(verify).dy, 0.5));
      expect(tester.getSize(surface).height, closeTo(tester.getSize(verify).height, 0.5));
      final paint = tester.widget<Container>(surface).decoration! as BoxDecoration;
      expect((paint.border! as Border).top.width, 1);
      expect(tester.getSize(surface).height, dark ? greaterThan(44.0) : equals(44.0));
      final edit = find.descendant(of: field, matching: find.byType(EditableText));
      expect(tester.getRect(surface).contains(tester.getCenter(edit)), isTrue);
      expect(tester.widget<TextField>(field).maxLength, 64);

      await tester.showKeyboard(field);
      await tester.pumpAndSettle();
      final shortHeight = tester.getSize(surface).height;
      await tester.enterText(field, 'W' * 64);
      await tester.pumpAndSettle();
      expect(tester.getSize(surface).height, greaterThan(shortHeight));
      expect(tester.getSize(verify).height, closeTo(tester.getSize(surface).height, .5));
      await tester.enterText(field, '');
      await tester.pumpAndSettle();
      expect(tester.getSize(surface).height, shortHeight);
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pumpAndSettle();
      final error = find.text('请输入优惠码');
      expect(error, findsOneWidget);
      expect(tester.getTopLeft(error).dy, greaterThan(tester.getBottomLeft(surface).dy));
      expect(tester.getSize(surface).height, closeTo(tester.getSize(verify).height, 0.5));
      expect(service.submitCalls, 0);
      verifyNever(() => service.checkCoupon(any(), any(), any()));
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [320.0, 1280.0]) {
    for (final renew in [false, true]) {
      testWidgets('checkout $width renew=$renew shows one complete plan', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.reset);
        const description =
            '<p><strong style="color:#245BA9">自带颜色 📦</strong></p>'
            '<p>流量：120 GB/月</p><ul><li>完整条目 1</li><li>完整条目 2</li></ul>';
        final plan = _plan.copyWith(description: description);
        final service = _Service();
        when(service.getSubscription).thenAnswer((_) async => const XbSuccess(
          XbDomainSubscription(
            email: 'fixture@example.test',
            uuid: 'fixture',
            totalBytes: 100,
            usedBytes: 0,
            planId: 7,
          ),
        ));
        when(() => service.checkCoupon('VALID', 7, XbPlanPeriod.yearly))
            .thenAnswer((_) async => const XbSuccess(_coupon));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              xboardServiceProvider.overrideWithValue(service),
              authStateProvider.overrideWith(_Auth.new),
            ],
            child: MaterialApp(
              home: PlanDetailPage(
                plan: plan,
                renew: renew,
                initialPeriod: XbPlanPeriod.monthly,
                confirmedFor: plan.id,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final name = find.descendant(
          of: find.byType(XbCard),
          matching: find.text(plan.name, findRichText: true),
        );
        final details = find.byType(XbPlanDetails);
        final html = find.byType(Html);
        final period = find.text(renew ? '选择续费时长' : '选择计费周期');
        final submit = find.widgetWithText(
          FilledButton,
          renew ? '确认续费' : '提交订单',
        );
        expect(name, findsOneWidget);
        expect(find.text('展开说明'), findsNothing);
        expect(find.text('收起说明'), findsNothing);
        // The same full four-row fixture previously measured 124 logical pixels.
        expect(tester.getSize(html).height, lessThan(124));
        expect(details, findsOneWidget);
        expect(find.descendant(of: details, matching: html), findsOneWidget);
        expect(tester.widget<Html>(html).data, contains('color:#245BA9'));
        for (final item in ['自带颜色', '120 GB/月', '完整条目 1', '完整条目 2']) {
          expect(
            find.descendant(
              of: html,
              matching: find.textContaining(item, findRichText: true),
            ),
            findsWidgets,
          );
        }
        expect(find.textContaining('10 GB', findRichText: true), findsNothing);
        expect(find.text('订单摘要'), findsNothing);
        expect(find.text('总计（预估）'), findsNothing);
        expect(find.text('完整套餐说明'), findsNothing);
        expect(
          tester.getBottomLeft(name).dy,
          lessThanOrEqualTo(tester.getTopLeft(details).dy),
        );
        if (width < 840) {
          expect(tester.getBottomLeft(details).dy, lessThan(tester.getTopLeft(submit).dy));
        } else {
          final infoBox = find.ancestor(of: details, matching: find.byType(XbCard)).first;
          final priceBox = find.ancestor(of: period, matching: find.byType(XbSectionCard)).first;
          expect(tester.getRect(infoBox).left, closeTo(tester.getRect(priceBox).left, 0.5));
          expect(tester.getRect(infoBox).right, closeTo(tester.getRect(priceBox).right, 0.5));
        }
        expect(tester.getBottomLeft(details).dy, lessThan(tester.getTopLeft(period).dy));
        expect(tester.getBottomLeft(details).dy, lessThan(tester.getTopLeft(find.byType(XbSelectableOption).first).dy));
        expect(find.text('¥10.00', findRichText: true), findsOneWidget);
        expect(find.text('¥100.00', findRichText: true), findsOneWidget);
        expect(service.submitCalls, 0);

        await tester.ensureVisible(find.byType(XbSelectableOption).last);
        await tester.tap(find.byType(XbSelectableOption).last);
        await tester.pumpAndSettle();
        expect(details, findsOneWidget);
        expect(service.submitCalls, 0);
        final field = find.byType(TextField);
        final verify = find.text('验证');
        await tester.ensureVisible(field);
        await tester.enterText(field, 'VALID');
        await tester.ensureVisible(verify);
        await tester.tap(verify);
        await tester.pumpAndSettle();
        expect(find.text('优惠券已应用'), findsOneWidget);
        expect(service.submitCalls, 0);

        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(service.submitCalls, 1);
        expect(service.submittedQuote?.period, XbPlanPeriod.yearly);
        expect(service.submittedQuote?.couponCode, 'VALID');
        expect(service.submittedQuote?.estimatedCents, 9900);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final scenario in [
        'dispose-success',
        'dispose-failure',
        'period',
        'edit',
        'selection',
        'composing',
        'pending-submit',
        'late-account',
        'empty',
        'reset-only',
      ]) {
        testWidgets('$brand $platform $scenario', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1280, 1100);
          addTearDown(tester.view.reset);
          XboardConfig.bind(
            XboardConfig(
              appName: brand,
              flavorId: brand,
              subscribeUserAgent: 'fixture',
              devApiEndpoint: '',
              devSubscriptionEndpoint: '',
              debug: true,
              kIsTest: true,
              formA: true,
            ),
          );
          addTearDown(XboardConfig.resetForTest);
          final service = _Service();
          final gate = Completer<XbResult<CouponInfo?>>();
          when(
            () => service.checkCoupon(any(), any(), any()),
          ).thenAnswer((_) => gate.future);
          final plan = scenario == 'empty' || scenario == 'reset-only'
              ? PlanItem(
                  id: 7,
                  name: '测试套餐',
                  transferEnableGb: 10,
                  prices: scenario == 'empty'
                      ? []
                      : [
                          const PricePlan(
                            period: XbPlanPeriod.resetTraffic,
                            amountYuan: 1,
                          ),
                        ],
                )
              : _plan;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                xboardServiceProvider.overrideWithValue(service),
                authStateProvider.overrideWith(_Auth.new),
              ],
              child: MaterialApp(
                theme: ThemeData(platform: platform),
                home: PlanDetailPage(plan: plan, renew: true),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (scenario == 'empty' || scenario == 'reset-only') {
            expect(find.textContaining('暂无可购买周期'), findsOneWidget);
            expect(find.text('确认续费'), findsNothing);
            expect(tester.takeException(), isNull);
            return;
          }
          await tester.enterText(find.byType(TextField), 'VALID');
          await tester.tap(find.text('验证'));
          await tester.pump();
          final verifying = find.widgetWithText(OutlinedButton, '正在验证…');
          expect(tester.widget<OutlinedButton>(verifying).onPressed, isNull);
          expect(find.descendant(of: verifying, matching: find.byType(CircularProgressIndicator)), findsNothing);
          if (scenario.startsWith('dispose')) {
            await tester.pumpWidget(const SizedBox());
          } else if (scenario == 'period') {
            await tester.tap(find.byType(XbSelectableOption).first);
            await tester.pump();
          } else if (scenario == 'pending-submit') {
            await tester.tap(find.text('确认续费'), warnIfMissed: false);
            await tester.pump();
            expect(service.submitCalls, 0);
            verifyNever(service.getSubscription);
          } else if (scenario == 'late-account') {
            ProviderScope.containerOf(tester.element(find.byType(PlanDetailPage)))
                .read(authStateProvider.notifier)
                .markAuthenticated();
          }
          gate.complete(
            scenario == 'dispose-failure'
                ? const XbFailure(XbNetwork(XbNetworkKind.timeout, 'fixture'))
                : const XbSuccess(_coupon),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (scenario == 'period' || scenario == 'late-account') {
            expect(find.text('优惠券已应用'), findsNothing);
          }
          if (scenario == 'selection' || scenario == 'composing') {
            expect(find.text('优惠券已应用'), findsOneWidget);
            final field = tester.widget<TextField>(find.byType(TextField));
            field.controller!.value = field.controller!.value.copyWith(
              selection: const TextSelection(baseOffset: 0, extentOffset: 2),
              composing: scenario == 'composing'
                  ? const TextRange(start: 0, end: 2)
                  : TextRange.empty,
            );
            await tester.pump();
            expect(field.controller!.text, 'VALID');
            expect(find.text('优惠券已应用'), findsOneWidget);
          }
          if (scenario == 'edit') {
            expect(find.text('优惠券已应用'), findsOneWidget);
            await tester.enterText(find.byType(TextField), 'OTHER');
            await tester.pump();
            expect(find.text('优惠券已应用'), findsNothing);
          }
        });
      }
    }
  }
}
