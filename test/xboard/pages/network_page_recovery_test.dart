/// Offline-first page opens must recover once, after a verified API probe.

import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/shop/shop_tab.dart';
import 'package:fl_clash/providers/state.dart'
    show isStartProvider, suspendProvider;
import 'package:fl_clash/xboard/providers/xboard_connectivity_provider.dart';
import 'package:fl_clash/xboard/services/xboard_network_observer.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import '../../_fixtures/fake_connectivity.dart';
import 'package:fl_clash/xboard/models/xb_tutorial.dart';
import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/pages/tutorial_list_page.dart';
import 'package:fl_clash/xboard/pages/share_friend_page.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';

class _SignedIn extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

class _MockService extends Mock implements XboardService {}

OrderSummary _order(String tradeNo, String planName, XbOrderStatus status) =>
    OrderSummary(
      tradeNo: tradeNo,
      planName: planName,
      period: XbPlanPeriod.monthly,
      totalAmountYuan: 12,
      status: status,
      createdAt: DateTime(2026, 6, 9, 11),
    );

void main() {
  for (final kind in ['orders', 'tutorial', 'share', 'shop'])
    testWidgets('verified API restores visible $kind without another tap', (
      t,
    ) async {
      final hw = FakeConnectivity();
      final svc = _MockService();
      var healthy = false, reads = 0;
      const err = XbNetwork(XbNetworkKind.timeout, 'test network down');
      when(
        () => svc.getOrders(page: 1, pageSize: 50, forceRefresh: true),
      ).thenAnswer((_) async {
        reads++;
        return healthy
            ? XbSuccess(
                XbPagedList(
                  items: [_order('A', '已恢复的订单', XbOrderStatus.completed)],
                  page: 1,
                  pageSize: 50,
                  total: 1,
                ),
              )
            : const XbFailure(err);
      });
      when(svc.getTutorials).thenAnswer((_) async {
        reads++;
        return healthy
            ? XbSuccess([
                XbTutorial(id: 1, title: '已恢复的教程', updatedAt: DateTime(2026)),
              ])
            : const XbFailure(err);
      });
      when(svc.getShareLink).thenAnswer((_) async {
        reads++;
        return healthy
            ? const XbSuccess(
                XbShareLink(
                  enabled: true,
                  primaryUrl: 'https://fixture.invalid',
                  backupUrl: '',
                ),
              )
            : const XbFailure(err);
      });
      when(svc.getPlans).thenAnswer((_) async {
        reads++;
        return healthy
            ? const XbSuccess([
                PlanItem(
                  id: 4,
                  name: '已恢复的套餐',
                  transferEnableGb: 100,
                  prices: [
                    PricePlan(period: XbPlanPeriod.monthly, amountYuan: 20),
                  ],
                ),
              ])
            : const XbFailure(err);
      });
      final c = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(_SignedIn.new),
          xboardServiceProvider.overrideWithValue(svc),
          isStartProvider.overrideWith((_) => false),
          suspendProvider.overrideWith((_) => false),
          xboardConnectivityClientProvider.overrideWithValue(hw),
          userProfileProvider.overrideWith(
            (_) async => const XbDomainSubscription(
              email: 'test@example.invalid',
              uuid: 'fixture',
              totalBytes: 100,
              usedBytes: 0,
            ),
          ),
        ],
      );
      c.read(bootstrapReadyProvider.notifier).set(true);
      final race = EndpointRaceController(
        probe: (_) async => healthy,
        onVerifiedNetwork: () =>
            c.read(networkRecoveryProvider.notifier).publish(),
      );
      race.seedEndpoints(const [
        BootstrapEndpoint(
          url: 'https://fixture.invalid',
          region: BootstrapRegion.unknown,
        ),
      ], []);
      final obs = XboardNetworkObserver(c, race);
      try {
        await t.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              home: Scaffold(
                body: switch (kind) {
                  'orders' => const OrderListPage(),
                  'tutorial' => const TutorialListPage(),
                  'share' => const ShareFriendPage(),
                  _ => ShopTab(active: true, mobile: true, onTapLogin: () {}),
                },
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(reads, 1);
        hw.goMobile();
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(c.read(networkRecoveryProvider), 0);
        expect(reads, 1);
        healthy = true;
        hw.goWifi();
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        await t.pumpAndSettle();
        expect(reads, 2);
        expect(
          find.text(switch (kind) {
            'orders' => '已恢复的订单',
            'tutorial' => '已恢复的教程',
            'share' => '主要地址',
            _ => '已恢复的套餐',
          }, findRichText: true),
          findsWidgets,
        );
        expect(c.read(networkRecoveryProvider), greaterThan(0));
        print(
          '$kind: no retry on failed probe, exactly one on verified recovery',
        );
      } finally {
        obs.dispose();
        race.dispose();
        await t.pumpWidget(const SizedBox());
        c.dispose();
        await hw.close();
      }
    });
}
