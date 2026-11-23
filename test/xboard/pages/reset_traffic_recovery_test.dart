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
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/xb_async_view.dart';

class _Service extends Mock implements XboardService {}

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

const _failed = XbFailure<List<PlanItem>>(
  XbNetwork(XbNetworkKind.timeout, 'fixture timeout'),
);
const _ready = XbSuccess<List<PlanItem>>([
  PlanItem(
    id: 7,
    name: 'fixture',
    transferEnableGb: 10,
    prices: [PricePlan(period: XbPlanPeriod.resetTraffic, amountYuan: 1)],
  ),
]);
void main() {
  for (final staleFirst in [false, true]) {
    testWidgets('changed plan owns its quote even when old read settles first=$staleFirst', (t) async {
      final first = Completer<XbResult<List<PlanItem>>>();
      final second = Completer<XbResult<List<PlanItem>>>();
      final service = _Service();
      var reads = 0;
      when(service.getPlans).thenAnswer((_) => ++reads == 1 ? first.future : second.future);
      final id = ValueNotifier<int>(6);
      addTearDown(id.dispose);
      await t.pumpWidget(ProviderScope(overrides: [
        authStateProvider.overrideWith(_Auth.new),
        xboardServiceProvider.overrideWithValue(service),
        userProfileProvider.overrideWith((_) async => const XbDomainSubscription(
          email: 'fixture@example.invalid', uuid: 'fixture', planId: 7, usedBytes: 10, totalBytes: 10)),
      ], child: MaterialApp(home: ValueListenableBuilder<int>(
        valueListenable: id, builder: (_, planId, _) => ResetTrafficPage(planId: planId)))));
      await t.pump();
      id.value = 7;
      await t.pump();
      expect(reads, 2);
      if (staleFirst) {
        first.complete(_failed);
        await t.pump();
        expect(find.text('重试'), findsNothing);
      }
      second.complete(_ready);
      await t.pumpAndSettle();
      if (!staleFirst) {
        first.complete(_failed);
        await t.pumpAndSettle();
      }
      expect(find.text('流量重置包'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      verifyNever(() => service.cancelOrder(any()));
    });
  }
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final scenario in [
        'success',
        'initial-throw',
        'unsupported',
        'dispose-success',
        'dispose-failure',
        'verified-recovery',
        'latest-failure',
      ]) {
        testWidgets('$brand $platform reset $scenario', (tester) async {
          tester.view.physicalSize = const Size(1280, 1100);
          tester.view.devicePixelRatio = 1;
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
          final pending = <Completer<XbResult<List<PlanItem>>>>[];
          when(() => service.getPlans()).thenAnswer((_) {
            final request = Completer<XbResult<List<PlanItem>>>();
            pending.add(request);
            return request.future;
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authStateProvider.overrideWith(_Auth.new),
                xboardServiceProvider.overrideWithValue(service),
                userProfileProvider.overrideWith(
                  (ref) async => const XbDomainSubscription(
                    email: 'fixture@example.invalid',
                    uuid: 'fixture',
                    planId: 7,
                    usedBytes: 10,
                    totalBytes: 10,
                  ),
                ),
              ],
              child: MaterialApp(
                theme: ThemeData(platform: platform),
                home: const ResetTrafficPage(planId: 7),
              ),
            ),
          );
          await tester.pump();
          if (scenario == 'initial-throw') {
            pending[0].completeError(StateError('fixture load exception'));
          } else {
            pending[0].complete(_failed);
          }
          await tester.pumpAndSettle();
          expect(find.text('重试'), findsOneWidget);
          final retry = tester
              .widget<XbAsyncView>(find.byType(XbAsyncView))
              .onRetry;
          final container = ProviderScope.containerOf(tester.element(find.byType(ResetTrafficPage)));
          if (scenario == 'verified-recovery') {
            container.read(networkRecoveryProvider.notifier).publish();
          } else {
            if (scenario == 'initial-throw') {
              container.read(networkRecoveryProvider.notifier).publish();
              await tester.pump();
              expect(pending.length, 1);
            }
            await tester.tap(find.text('重试'));
          }
          await tester.pump();
          expect(pending.length, 2);
          if (scenario.startsWith('dispose')) {
            await tester.pumpWidget(const SizedBox());
            pending[1].complete(
              scenario == 'dispose-success' ? _ready : _failed,
            );
          } else if (scenario == 'verified-recovery' || scenario == 'latest-failure') {
            retry();
            await tester.pump();
            expect(pending.length, 2);
            pending[1].complete(scenario == 'latest-failure' ? _failed : _ready);
          } else {
            pending[1].complete(
              scenario == 'unsupported' ? const XbSuccess([]) : _ready,
            );
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (scenario.startsWith('dispose')) return;
          if (scenario == 'latest-failure') {
            expect(find.text('重试'), findsOneWidget);
            expect(find.text('流量重置包'), findsNothing);
          } else {
            expect(find.text('重试'), findsNothing);
            expect(
              find.text(
                scenario == 'unsupported' ? '当前套餐不支持单独购买流量重置包' : '流量重置包',
              ),
              findsOneWidget,
            );
          }
        });
      }
    }
  }
}
