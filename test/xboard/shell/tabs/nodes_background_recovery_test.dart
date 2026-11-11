/// D04: retain the real page and account provider across subscription recovery.
/// HTTP/sync and Core group inputs are controlled; this is not a device test.
library;
import '../../../_fixtures/xb_action_finders.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show Group, PatchClashConfig, ProxiesTabState, Proxy;
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/subscription_sync_status.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/nodes_tab.dart';
import 'package:fl_clash/xboard/widgets/xb_refresh_throttle_guard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements XboardService {}
class _Sync extends Mock implements XboardSubscriptionService {}
class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

void main() {
  test('sync status retains business errors on transient failure and rejects old sessions', () {
    final container = ProviderContainer(overrides: [authStateProvider.overrideWith(_Auth.new)]);
    addTearDown(container.dispose);
    final auth = container.read(authStateProvider.notifier);
    final status = container.read(subscriptionSyncStatusProvider.notifier);
    final revision = auth.sessionRevision;
    status.publish(XbSyncOutcome.noSubscription, revision);
    status.publish(XbSyncOutcome.failed, revision);
    status.publish(XbSyncOutcome.skipped, revision);
    expect(container.read(subscriptionSyncStatusProvider)?.outcome, XbSyncOutcome.noSubscription);
    auth.markUnauthenticated();
    status.publish(XbSyncOutcome.ok, revision);
    expect(container.read(subscriptionSyncStatusProvider), isNull);
  });

  for (final flavor in ['brand_a', 'brand_b']) {
    for (final manual in [false, true]) {
      testWidgets('D04 $flavor ${manual ? 'manual control' : 'background recovery'}', (tester) async {
        XboardConfig.bind(XboardConfig(
          subscribeUserAgent: 'gap-validation',
          devApiEndpoint: 'https://example.invalid',
          devSubscriptionEndpoint: 'https://example.invalid',
          flavorId: flavor,
          debug: false,
          kIsTest: true,
          formA: true,
        ));
        final service = _Service();
        final sync = _Sync();
        late ProviderContainer container;
        var outcome = XbSyncOutcome.noSubscription;
        var accountLoads = 0;
        const profile = XbDomainSubscription(
          email: 'fixture@example.invalid', uuid: 'fixture', planId: 1,
          planName: 'fixture', totalBytes: 1000000, usedBytes: 1,
        );
        when(service.getSubscription).thenAnswer((_) async {
          accountLoads++;
          return XbResult.success(profile);
        });
        when(() => sync.sync(force: true)).thenAnswer((_) async {
          // Mirror the production provider's onOutcome wiring; the real service
          // observer and stale-session suppression have separate service tests.
          container.read(subscriptionSyncStatusProvider.notifier).publish(
            outcome, container.read(authStateProvider.notifier).sessionRevision);
          return outcome;
        });
        const group = Group(type: GroupType.Selector, name: 'fixture-group',
          now: 'recovered-node', all: [Proxy(name: 'recovered-node', type: 'ss')]);
        container = ProviderContainer(overrides: [
          authStateProvider.overrideWith(_Auth.new),
          xboardServiceProvider.overrideWithValue(service),
          subscriptionServiceProvider.overrideWithValue(sync),
          proxiesTabStateProvider.overrideWith((ref) => const ProxiesTabState(
            groups: [group], currentGroupName: 'fixture-group',
            proxyCardType: ProxyCardType.standard)),
          patchClashConfigProvider.overrideWithBuild((ref, _) => const PatchClashConfig(mode: Mode.rule)),
          selectedProxyNameProvider(group.name).overrideWithValue(group.now),
          proxyNameProvider(group.name).overrideWithValue(null),
          delayProvider(proxyName: 'recovered-node', testUrl: null).overrideWithValue(48),
        ]);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          XboardConfig.resetForTest();
        });
        await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: const MaterialApp(home: Scaffold(body: NodesTab()))));
        await tester.pumpAndSettle();
        expect(find.text('recovered-node', findRichText: true), findsOneWidget);
        final page = tester.state(find.byType(NodesTab));
        await tester.tap(findActionLabel('刷新节点'));
        await tester.pumpAndSettle();
        expect(find.text('当前无可用线路'), findsOneWidget);
        expect(find.text('recovered-node', findRichText: true), findsNothing);
        final before = accountLoads;
        outcome = XbSyncOutcome.ok;
        if (manual) {
          // The production guard uses real Stopwatch, not WidgetTester time.
          // Clear only its timer for this positive control, never the outcome.
          (page as XbRefreshThrottleGuard).resetThrottle();
          container.invalidate(userProfileProvider);
          await container.read(userProfileProvider.future);
          await tester.pumpAndSettle();
          expect(find.text('当前无可用线路'), findsOneWidget);
          await tester.tap(findActionLabel('刷新节点'));
        } else {
          // Deliver a successful background result and refresh the real provider,
          // without replacing/remounting the page or overriding userProfile.
          expect(await container.read(subscriptionServiceProvider).sync(force: true), XbSyncOutcome.ok);
          container.invalidate(userProfileProvider);
          expect(await container.read(userProfileProvider.future), same(profile));
        }
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(NodesTab)), same(page));
        expect(accountLoads, greaterThan(before));
        expect(find.text('recovered-node', findRichText: true), findsOneWidget,
          reason: 'Valid account and available groups must recover the retained page');
      });
    }
  }
}
