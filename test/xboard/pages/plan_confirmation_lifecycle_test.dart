import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/pages/order_payment_page.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/pending_order_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class _Service extends Mock implements XboardService {}

const _plan = PlanItem(id: 7, name: 'new plan', transferEnableGb: 100,
    prices: [PricePlan(period: XbPlanPeriod.monthly, amountYuan: 10)]);

void main() {
  setUpAll(() => registerFallbackValue(XbPlanPeriod.monthly));
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [TargetPlatform.android, TargetPlatform.windows,
      TargetPlatform.macOS, TargetPlatform.linux]) {
      for (final mode in ['normal-success', 'normal-failure', 'cancel',
        'confirmation-session', 'confirmation-service', 'confirmation-both', 'confirmation-dispose',
        'late-session-success', 'late-service-success', 'late-both-success',
        'late-session-failure', 'late-service-failure',
        'late-session-unconfirmed', 'late-service-unconfirmed', 'late-dispose']) {
        testWidgets('$brand $platform $mode', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(platform == TargetPlatform.android ? 430 : 1280, 1100);
          addTearDown(tester.view.reset);
          XboardConfig.bind(XboardConfig(appName: brand, flavorId: brand,
              subscribeUserAgent: 'fixture', devApiEndpoint: '', devSubscriptionEndpoint: '',
              debug: true, kIsTest: true, formA: true));
          addTearDown(XboardConfig.resetForTest);
          final a = _Service(), b = _Service();
          XboardService service = a;
          final visible = ValueNotifier(true);
          addTearDown(visible.dispose);
          final response = Completer<XbResult<String>>();
          when(() => a.createOrder(any(), any(), couponCode: any(named: 'couponCode')))
              .thenAnswer((_) => response.future);
          when(() => b.createOrder(any(), any(), couponCode: any(named: 'couponCode')))
              .thenAnswer((_) async => const XbFailure(XbUnexpected('createOrder', 'wrong-service')));
          when(() => a.getOrder(any())).thenAnswer((_) async => const XbSuccess(null));
          when(() => a.getPaymentMethods()).thenAnswer((_) async => const XbSuccess([]));
          await tester.pumpWidget(ProviderScope(overrides: [
            xboardServiceProvider.overrideWith((ref) => service),
            userProfileProvider.overrideWith((ref) async => const XbDomainSubscription(
                email: 'fixture@example.test', uuid: 'fixture', planName: 'old plan',
                planId: 1, totalBytes: 100, usedBytes: 0)),
            pendingOrderProvider.overrideWith((ref) async => null),
          ], child: MaterialApp(theme: ThemeData(platform: platform),
              home: ValueListenableBuilder<bool>(valueListenable: visible,
                builder: (_, show, _) => show ? const PlanDetailPage(plan: _plan) : const SizedBox()))));
          await tester.pumpAndSettle();
          final container = ProviderScope.containerOf(tester.element(find.byType(PlanDetailPage)));
          await container.read(userProfileProvider.future);
          await tester.tap(find.text('提交订单'));
          await tester.pump();
          // The submit spinner intentionally stays active behind this dialog.
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('确认更换套餐？'), findsOneWidget);

          void changeContext() {
            if (mode.contains('session') || mode.contains('both')) {
              final auth = container.read(authStateProvider.notifier);
              final before = auth.sessionRevision;
              auth.markAuthenticated();
              expect(auth.sessionRevision, greaterThan(before));
            }
            if (mode.contains('service') || mode.contains('both')) {
              service = b;
              container.invalidate(xboardServiceProvider);
            }
            if (mode.contains('dispose')) visible.value = false;
          }
          if (mode.startsWith('confirmation')) {
            changeContext();
            await tester.pump();
          }
          if (mode == 'cancel') {
            await tester.tap(find.text('再想想'));
          } else {
            await tester.tap(find.text('确认更换'));
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          if (mode.startsWith('confirmation') || mode == 'cancel') {
            verifyNever(() => a.createOrder(any(), any(), couponCode: any(named: 'couponCode')));
          } else {
            verify(() => a.createOrder(7, XbPlanPeriod.monthly, couponCode: null)).called(1);
            if (mode.startsWith('late')) changeContext();
            await tester.pump();
            response.complete(mode.endsWith('success')
                ? const XbSuccess('fixture-trade')
                : mode.endsWith('unconfirmed')
                    ? const XbFailure(XbUnconfirmed('createOrder', 'fixture late unconfirmed'))
                    : const XbFailure(XbUnexpected('createOrder', 'fixture late failure')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
          }
          verifyNever(() => b.createOrder(any(), any(), couponCode: any(named: 'couponCode')));
          if (mode == 'normal-success') {
            expect(find.byType(OrderPaymentPage), findsOneWidget);
          } else if (mode == 'normal-failure') {
            expect(find.textContaining('fixture late failure'), findsOneWidget);
          } else {
            expect(find.byType(OrderPaymentPage), findsNothing);
            expect(find.byType(OrderListPage), findsNothing);
            expect(find.textContaining('fixture late'), findsNothing);
            expect(find.textContaining('wrong-service'), findsNothing);
          }
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
