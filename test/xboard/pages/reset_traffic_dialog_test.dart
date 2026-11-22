import 'dart:async';
import 'dart:ui' show ImageByteFormat;

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/confirmed_order.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/pages/order_payment_page.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_expiry_card.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_traffic_notice.dart';
import 'package:fl_clash/xboard/util/format.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;

  void switchAccount() {
    state = AuthState.unauthenticated;
    markAuthenticated();
  }
}

class _Service extends Mock
    implements XboardService, XboardConfirmedOrderControl {
  final quotes = <ConfirmedOrderQuote>[];
  bool Function()? requestActive;
  Completer<XbResult<String?>>? response;

  @override
  Future<XbResult<String?>> confirmOrder(
    ConfirmedOrderQuote quote, {
    required bool Function() isActive,
    required Future<bool> Function(ConfirmedOrderConflict) confirm,
  }) async {
    requestActive = isActive;
    quotes.add(quote);
    final pending = response;
    return pending == null ? const XbSuccess(null) : await pending.future;
  }
}

PlanItem _catalog(double? amount) => PlanItem(
  id: 7,
  name: 'fixture',
  transferEnableGb: 100,
  prices: [
    if (amount != null)
      PricePlan(period: XbPlanPeriod.resetTraffic, amountYuan: amount),
  ],
);

Future<void> _expectPaintedWhite(
  WidgetTester tester,
  Key captureKey,
  Finder label,
) async {
  final paragraph = tester.renderObject<RenderParagraph>(label);
  expect(paragraph.text.style?.color, Colors.white);
  final capture = find.byKey(captureKey);
  final rect = tester.getRect(label).shift(-tester.getTopLeft(capture));
  final boundary = tester.renderObject<RenderRepaintBoundary>(capture);
  final whitePixels = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(format: ImageByteFormat.rawRgba))!;
      var count = 0;
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
        for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
          final i = (y * image.width + x) * 4;
          if (data.getUint8(i) >= 250 &&
              data.getUint8(i + 1) >= 250 &&
              data.getUint8(i + 2) >= 250) {
            count++;
          }
        }
      }
      return count;
    } finally {
      image.dispose();
    }
  });
  expect(whitePixels, greaterThan(0));
}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final scenario in [
      'accept',
      'navigate to receipt',
      'known zero price',
      'decline',
      'unknown price',
      'invalid price',
      'unknown reset date',
      'same day reset fallback',
      'expired',
      'threshold lost',
      'close during load',
      'switch account during load',
      'close during submit',
    ]) {
      testWidgets('$brand home 80 percent reset: $scenario', (tester) async {
        XboardConfig.bind(
          XboardConfig(
            appName: brand,
            flavorId: brand,
            brandColor: brand == 'brand_a' ? 0xFFD92E1A : 0xFF245BA9,
            subscribeUserAgent: 'fixture',
            devApiEndpoint: '',
            devSubscriptionEndpoint: '',
            debug: true,
            kIsTest: true,
            formA: true,
          ),
        );
        addTearDown(XboardConfig.resetForTest);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(
          brand == 'brand_a' || scenario == 'accept' ? 320 : 1000,
          800,
        );
        addTearDown(tester.view.reset);
        final brightness =
            brand == 'brand_a' ? Brightness.light : Brightness.dark;
        final scale = brand == 'brand_b' && scenario == 'accept' ? 2.0 : 1.0;
        final service = _Service();
        if (scenario == 'close during submit' || scenario == 'navigate to receipt') {
          service.response = Completer<XbResult<String?>>();
        }
        final plans = Completer<XbResult<List<PlanItem>>>();
        when(() => service.getPlans()).thenAnswer((_) => plans.future);
        final now = DateTime.now();
        final expiry = now.add(
          scenario == 'expired'
              ? const Duration(days: -1)
              : const Duration(days: 7, hours: 1),
        );
        final resetAt =
            scenario == 'unknown reset date' ||
                scenario == 'same day reset fallback'
            ? null
            : now.add(const Duration(days: 6, hours: 1));
        var profile = XbDomainSubscription(
          email: 'fixture@example.invalid',
          uuid: 'fixture',
          planId: 7,
          planName: 'fixture',
          usedBytes: 800,
          totalBytes: 1000,
          expiredAt: expiry,
          nextResetAt: resetAt,
          resetDay: switch (scenario) {
            'unknown reset date' => null,
            'same day reset fallback' => 0,
            _ => 88,
          },
        );
        final container = ProviderContainer(
          overrides: [
            authStateProvider.overrideWith(_Auth.new),
            userProfileProvider.overrideWith((ref) async => profile),
            xboardServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: ThemeData(brightness: brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: child!,
                ),
                home: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const Scaffold(
                  body: Column(
                    children: [XbExpiryCard(), XbTrafficNotice()],
                  ),
                ))),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('重置流量'));
        await tester.pump();
        expect(find.text('流量重置包购买须知'), findsOneWidget);
        final modalContext = tester.element(find.byType(AlertDialog));
        expect(ModalRoute.of(modalContext)!.navigator, same(Navigator.of(modalContext, rootNavigator: true)));
        expect(find.byType(XbTrafficNotice), findsOneWidget);
        expect(find.text('已用流量：80.0%'), findsOneWidget);
        expect(find.text(xbDateMinute(expiry)), findsOneWidget);
        if (scenario == 'expired') {
          expect(find.text('已过期'), findsOneWidget);
        } else {
          expect(find.text('剩余7天'), findsOneWidget);
          // The reset dialog shows whole days; the separate home expiry card
          // only appears at or below seven actual days (this fixture is 7d1h).
          expect(find.textContaining('仅剩 7 天'), findsNothing);
        }
        if (resetAt != null) {
          expect(find.text(xbDateMinute(resetAt)), findsOneWidget);
          expect(find.text('剩余6天'), findsOneWidget);
          expect(find.text('剩余 88 天'), findsNothing);
        } else {
          expect(
            find.text(scenario == 'unknown reset date' ? '未提供' : '今天'),
            findsOneWidget,
          );
        }
        final confirm = find.widgetWithText(FilledButton, '确认购买');
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        if (scenario == 'close during load') {
          await tester.tap(find.text('再想想'));
          await tester.pump();
        }
        if (scenario == 'switch account during load') {
          (container.read(authStateProvider.notifier) as _Auth).switchAccount();
        }
        plans.complete(
          XbSuccess([
            _catalog(switch (scenario) {
              'unknown price' => null,
              'invalid price' => double.nan,
              'known zero price' => 0.0,
              _ => 16.27,
            }),
          ]),
        );
        await tester.pumpAndSettle();
        switch (scenario) {
          case 'accept':
          case 'known zero price':
            final zero = scenario == 'known zero price';
            final price = find.text(zero ? '¥0.00' : '¥16.27');
            expect(price, findsOneWidget);
            expect(tester.widget<Text>(price).textAlign, TextAlign.end);
            final priceRight = tester.getTopRight(price).dx;
            for (final date in [expiry, resetAt!]) {
              final dateLabel = find.text(xbDateMinute(date));
              expect(tester.widget<Text>(dateLabel).textAlign, TextAlign.end);
              expect(tester.getTopRight(dateLabel).dx, closeTo(priceRight, 0.5));
            }
            final cancel = find.widgetWithText(FilledButton, '再想想');
            final dialogContext = tester.element(cancel);
            final tokens = XbTokens.of(dialogContext);
            expect(
              tester.widget<FilledButton>(cancel).style!.backgroundColor!.resolve({}),
              Color.lerp(tokens.sf2, tokens.sfc, 0.64),
            );
            final gradient = tester.widget<DecoratedBox>(
              find.ancestor(
                of: confirm,
                matching: find.byWidgetPredicate((widget) {
                  if (widget is! DecoratedBox) return false;
                  final decoration = widget.decoration;
                  return decoration is BoxDecoration &&
                      decoration.gradient is LinearGradient;
                }),
              ).first,
            ).decoration as BoxDecoration;
            final brandColor = Theme.of(dialogContext).colorScheme.primary;
            expect((gradient.gradient! as LinearGradient).colors, [
              brand == 'brand_a' ? const Color(0xffff5a44) : Color.lerp(brandColor, Colors.white, 0.16)!, brandColor,
            ]);
            await _expectPaintedWhite(tester, captureKey, find.text('确认购买'));
            await tester.tap(confirm);
            await tester.pumpAndSettle();
            final quote = service.quotes.single;
            expect(quote.planId, 7);
            expect(quote.period, XbPlanPeriod.resetTraffic);
            expect(quote.estimatedCents, zero ? 0 : 1627);
            expect(quote.expectedSubscription?.planId, 7);
            expect(find.text('流量重置包购买须知'), findsOneWidget);
          case 'navigate to receipt':
            await tester.tap(confirm);
            await tester.pump();
            service.response!.complete(const XbSuccess('DEMO-TEST'));
            await tester.pumpAndSettle();
            final receiptContext = tester.element(find.byType(OrderPaymentPage));
            expect(Navigator.of(receiptContext), isNot(same(Navigator.of(receiptContext, rootNavigator: true))));
            expect(find.byType(AlertDialog), findsNothing);
          case 'close during submit':
            await tester.tap(confirm);
            await tester.pumpAndSettle();
            expect(service.requestActive!(), isTrue);
            await tester.binding.handlePopRoute();
            expect(service.requestActive!(), isFalse);
            service.response!.complete(const XbSuccess('stale-trade'));
            await tester.pumpAndSettle();
            expect(find.text('流量重置包购买须知'), findsNothing);
            expect(find.byType(XbTrafficNotice), findsOneWidget);
          case 'decline':
            await tester.tap(find.text('再想想'));
            await tester.pumpAndSettle();
            expect(find.text('流量重置包购买须知'), findsNothing);
          case 'expired':
            expect(find.textContaining('当前套餐已过期'), findsOneWidget);
            expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
          case 'threshold lost':
            final submit = tester.widget<FilledButton>(confirm).onPressed!;
            profile = profile.copyWith(usedBytes: 799);
            container.invalidate(userProfileProvider);
            await tester.pumpAndSettle();
            expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
            expect(find.textContaining('账号或套餐状态已变化'), findsOneWidget);
            submit();
            await tester.pumpAndSettle();
          case 'unknown reset date':
            expect(find.textContaining('如有自动重置'), findsOneWidget);
            expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
          case 'same day reset fallback':
            expect(find.text('今天'), findsOneWidget);
            expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
          case 'close during load':
            expect(find.text('流量重置包购买须知'), findsNothing);
          case 'switch account during load':
            expect(find.textContaining('账号或套餐状态已变化'), findsOneWidget);
            expect(find.textContaining('¥16.27'), findsNothing);
          default:
            expect(find.textContaining('未提供有效价格'), findsOneWidget);
            expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        }
        if (scenario != 'accept' &&
            scenario != 'navigate to receipt' &&
            scenario != 'known zero price' &&
            scenario != 'close during submit') {
          expect(service.quotes, isEmpty);
        }
        verifyNever(() => service.createOrder(7, XbPlanPeriod.resetTraffic));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
