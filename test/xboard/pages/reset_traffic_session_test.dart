import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/pending_order_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/pages/order_payment_page.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';

class _Service extends Mock implements XboardService {}

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
  void leave() => state = AuthState.unauthenticated;
}

const _plan = PlanItem(
  id: 7,
  name: 'fixture',
  transferEnableGb: 100,
  prices: [PricePlan(period: XbPlanPeriod.resetTraffic, amountYuan: 10)],
);
void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final phase in ['normal', 'pending', 'before', 'loading']) {
        for (final change
            in phase == 'normal'
                ? ['none']
                : ['logout', 'account', 'service', 'dispose']) {
          for (final outcome
              in phase == 'before'
                  ? ['success']
                  : ['success', 'failure', 'unconfirmed', 'throw']) {
            testWidgets('$brand $platform $phase $change $outcome', (t) async {
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
              t.view.devicePixelRatio = 1;
              t.view.physicalSize = Size(
                platform == TargetPlatform.android ? 390 : 1100,
                1000,
              );
              addTearDown(t.view.reset);
              final a = _Service(), b = _Service();
              XboardService service = a;
              final response = Completer<XbResult<String>>(),
                  plans = Completer<XbResult<List<PlanItem>>>();
              when(() => a.getPlans()).thenAnswer(
                (_) => phase == 'loading'
                    ? plans.future
                    : Future.value(const XbSuccess([_plan])),
              );
              when(
                () => a.createOrder(7, XbPlanPeriod.resetTraffic),
              ).thenAnswer((_) => response.future);
              for (final s in [a, b]) {
                when(
                  () => s.getOrder('fixture-order'),
                ).thenAnswer((_) async => const XbSuccess(null));
                when(
                  () => s.getOrders(
                    page: any(named: 'page'),
                    pageSize: any(named: 'pageSize'),
                    forceRefresh: any(named: 'forceRefresh'),
                  ),
                ).thenAnswer(
                  (_) async => const XbSuccess(
                    XbPagedList<OrderSummary>(
                      items: [],
                      page: 1,
                      pageSize: 20,
                      total: 0,
                    ),
                  ),
                );
              }
              final c = ProviderContainer(
                overrides: [
                  authStateProvider.overrideWith(_Auth.new),
                  pendingOrderProvider.overrideWith((ref) async => null),
                  xboardServiceProvider.overrideWith((ref) => service),
                ],
              );
              addTearDown(c.dispose);
              await t.pumpWidget(
                UncontrolledProviderScope(
                  container: c,
                  child: MaterialApp(
                    theme: ThemeData(platform: platform),
                    home: const ResetTrafficPage(planId: 7),
                  ),
                ),
              );
              if (phase != 'loading') {
                await t.pumpAndSettle();
              } else {
                await t.pump();
              }
              Future<void> changeContext() async {
                final auth = c.read(authStateProvider.notifier) as _Auth;
                if (change == 'logout') auth.leave();
                if (change == 'account') {
                  auth.leave();
                  auth.markAuthenticated();
                }
                if (change == 'service') {
                  service = b;
                  c.invalidate(xboardServiceProvider);
                }
                if (change == 'dispose') await t.pumpWidget(const SizedBox());
              }

              VoidCallback? submit;
              if (phase != 'loading') {
                submit = t
                    .widget<FilledButton>(
                      find
                          .ancestor(
                            of: find.text('提交订单').last,
                            matching: find.byWidgetPredicate(
                              (w) => w is FilledButton,
                            ),
                          )
                          .first,
                    )
                    .onPressed;
              }
              if (phase == 'before') {
                await changeContext();
                submit!();
                await t.pump();
              } else if (phase == 'loading') {
                await changeContext();
                if (outcome == 'throw') {
                  plans.completeError(StateError('fixture throw'));
                } else {
                  plans.complete(
                    outcome == 'success'
                        ? const XbSuccess([_plan])
                        : const XbFailure(
                            XbUnexpected('getPlans', 'fixture failure'),
                          ),
                  );
                }
                await t.pump();
              } else {
                await t.tap(find.text('提交订单').last);
                await t.pump();
                // Repeated taps while pending must not issue another write.
                submit!();
                if (phase == 'pending') await changeContext();
                if (outcome == 'throw') {
                  response.completeError(StateError('fixture throw'));
                } else {
                  response.complete(
                    outcome == 'success'
                        ? const XbSuccess('fixture-order')
                        : outcome == 'unconfirmed'
                        ? const XbFailure(
                            XbUnconfirmed('createOrder', 'fixture unconfirmed'),
                          )
                        : const XbFailure(
                            XbUnexpected('createOrder', 'fixture failure'),
                          ),
                  );
                }
                await t.pump();
              }
              await t.pump(const Duration(milliseconds: 450));
              if (phase == 'normal') {
                if (outcome == 'success') {
                  expect(find.byType(OrderPaymentPage), findsOneWidget);
                  verify(() => a.getOrder('fixture-order')).called(1);
                } else if (outcome == 'failure') {
                  expect(
                    find.textContaining('fixture failure'),
                    findsOneWidget,
                  );
                  expect(find.byType(OrderPaymentPage), findsNothing);
                } else {
                  expect(find.byType(OrderListPage), findsOneWidget);
                }
              } else {
                expect(find.byType(OrderPaymentPage), findsNothing);
                expect(find.byType(OrderListPage), findsNothing);
                expect(find.textContaining('fixture failure'), findsNothing);
                expect(
                  find.textContaining('fixture unconfirmed'),
                  findsNothing,
                );
                expect(find.textContaining('订单结果暂未确认'), findsNothing);
                verifyNever(() => b.getOrder('fixture-order'));
                if (change != 'dispose') {
                  expect(find.text('账号状态已变化'), findsOneWidget);
                }
              }
              if (phase == 'before' || phase == 'loading') {
                verifyNever(() => a.createOrder(7, XbPlanPeriod.resetTraffic));
              } else {
                verify(
                  () => a.createOrder(7, XbPlanPeriod.resetTraffic),
                ).called(1);
              }
              verifyNever(() => b.createOrder(7, XbPlanPeriod.resetTraffic));
              expect(t.takeException(), isNull);
              await t.pump(const Duration(seconds: 3));
              await t.pumpWidget(const SizedBox());
            });
          }
        }
      }
    }
  }
}
