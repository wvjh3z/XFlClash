/// UB-GAP-22/27: keep testNode and ProxiesAction real; replace only Core I/O.
library;

import 'dart:async';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/xb_node_group.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbSpinner;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import '../../../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {}
const _url = 'https://fixture.invalid/delay';

void main() {
  setUpAll(() => registerFallbackValue(
    const TestDelayParams(proxyName: 'fixture', testUrl: _url, timeout: 100)));
  testWidgets('nested selector retries keep the initial leaf and URL', (tester) async {
    final core = _Core();
    final first = Completer<Delay>();
    final seen = <TestDelayParams>[];
    when(() => core.testDelay(any())).thenAnswer((call) {
      seen.add(call.positionalArguments.single as TestDelayParams);
      if (seen.length == 1) return first.future;
      throw TimeoutException('no response');
    });
    const child = Group(type: GroupType.Selector, name: 'nested', now: 'A',
        testUrl: _url, all: [Proxy(name: 'A', type: 'ss'), Proxy(name: 'B', type: 'ss')]);
    const parent = Group(type: GroupType.Selector, name: 'parent',
        testUrl: _url, all: [Proxy(name: 'nested', type: 'Selector')]);
    const profile = Profile(id: 1, label: 'fixture',
        autoUpdateDuration: Duration.zero, selectedMap: {'nested': 'A'});
    final container = ProviderContainer(overrides: [
      coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      profilesProvider.overrideWith(() => TestProfiles([profile])),
      currentProfileIdProvider.overrideWithBuild((_, _) => 1),
      groupsProvider.overrideWithBuild((_, _) => [parent, child]),
      proxiesTabStateProvider.overrideWith((_) => const ProxiesTabState(
          groups: [parent, child], currentGroupName: 'parent', proxyCardType: ProxyCardType.standard)),
      realTestUrlProvider(_url).overrideWithValue(_url),
    ]);
    late WidgetRef widgetRef;
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: Consumer(builder: (_, ref, _) { widgetRef = ref; return const SizedBox(); })));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
    container.read(delayDataSourceProvider.notifier).setDelay(
        const Delay(name: 'B', url: _url, value: 123));
    final flight = const XbNodesAdapter().testGroupDelay(widgetRef, 'parent');
    await tester.pump();
    expect(seen.single.proxyName, 'A');
    container.read(profilesProvider.notifier).put(profile.copyWith(selectedMap: {'nested': 'B'}));
    first.completeError(TimeoutException('first no response'));
    await flight;
    await tester.pump(const Duration(milliseconds: 1));
    expect(seen.map((p) => p.proxyName), ['A', 'A', 'A']);
    expect(seen.map((p) => p.testUrl), everyElement(_url));
    expect(container.read(delayProvider(proxyName: 'A', testUrl: _url)), -1);
    expect(container.read(delayProvider(proxyName: 'B', testUrl: _url)), 123,
        reason: 'B was not part of this frozen measurement; do not overwrite its sample');
    expect(container.read(xbMeasuringNodesProvider), isEmpty);
  });
  for (final brand in ['brand_a', 'brand_b']) {
    for (final scenario in ['old-null', 'old-positive', 'old-negative', 'fresh-control', 'leave-retry', 'leave-pool', 'single-null', 'single-positive', 'dispose-owner']) {
      testWidgets('$brand production group $scenario', (tester) async {
        XboardConfig.bind(XboardConfig(subscribeUserAgent: 'gap-validation',
          devApiEndpoint: 'https://fixture.invalid', devSubscriptionEndpoint: 'https://fixture.invalid',
          flavorId: brand, kIsTest: true, debug: false, formA: true));
        final core = _Core();
        var calls = 0;
        final pending = <({TestDelayParams params, Completer<Delay> reply})>[];
        when(() => core.testDelay(any())).thenAnswer((invocation) async {
          final params = invocation.positionalArguments.single as TestDelayParams;
          calls++;
          if (scenario.startsWith('leave-') && calls > (scenario == 'leave-pool' ? 10 : 1)) {
            return Delay(name: params.proxyName, url: params.testUrl, value: 120);
          }
          if (scenario.startsWith('leave-') || scenario.startsWith('single-') || scenario == 'dispose-owner') {
            final reply = Completer<Delay>();
            pending.add((params: params, reply: reply));
            return reply.future;
          }
          if (scenario == 'fresh-control') {
            return Delay(name: params.proxyName, url: params.testUrl, value: calls == 1 ? -1 : 120);
          }
          throw TimeoutException('synthetic no response');
        });
        final group = Group(type: GroupType.Selector, name: 'fixture-group', testUrl: _url,
          all: List.generate(scenario == 'leave-pool' ? 11 : 1, (i) => Proxy(name: 'node-$i', type: 'ss')));
        final container = ProviderContainer(overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          profilesProvider.overrideWith(() => TestProfiles([])),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          groupsProvider.overrideWithBuild((_, _) => [group]),
          proxiesTabStateProvider.overrideWith((ref) => ProxiesTabState(groups: [group],
            currentGroupName: group.name, proxyCardType: ProxyCardType.standard)),
          realTestUrlProvider(_url).overrideWithValue(_url),
        ]);
        var ownerDisposed = false;
        final old = scenario == 'old-positive' || scenario == 'single-positive'
            ? 123 : scenario == 'old-negative' ? -1 : null;
        if (old != null) {
          container.read(delayDataSourceProvider.notifier).setDelay(
            Delay(name: 'node-0', url: _url, value: old));
        }
        late WidgetRef widgetRef;
        await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: Consumer(builder: (context, ref, child) {
            widgetRef = ref;
            if (!scenario.startsWith('single-')) return const SizedBox();
            return const MaterialApp(home: Scaffold(body: XbNodeGroup(group: XbGroupSummary(
              name: 'fixture-group', nodeCount: 1, currentSelected: 'node-0',
              isUrlTest: false, kind: XbGroupKind.selector, testUrl: _url,
              nodes: [XbNodeItem(name: 'node-0', type: 'ss', testUrl: _url)],
            ))));
          })));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          if (!ownerDisposed) container.dispose();
          XboardConfig.resetForTest();
        });
        Object? failure;
        final operation = scenario.startsWith('single-')
            ? const XbNodesAdapter().testNode(widgetRef, proxyName: 'node-0', type: 'ss', testUrl: _url)
            : const XbNodesAdapter().testGroupDelay(widgetRef, group.name);
        final flight = operation
          .then<void>((_) {}, onError: (Object error, StackTrace stack) { failure = error; });
        await tester.pump();
        if (scenario.startsWith('single-')) {
          expect(calls, 1);
          expect(container.read(delayTestPhaseProvider(proxyName: 'node-0', testUrl: _url)), isNotNull);
          expect(container.read(xbMeasuringNodesProvider), isEmpty);
          expect(find.byType(XbSpinner), findsOneWidget);
          if (old != null) expect(find.text('61 ms'), findsNothing);
          pending.single.reply.complete(const Delay(name: 'node-0', url: _url, value: 120));
        }
        if (scenario.startsWith('leave-')) {
          expect(calls, scenario == 'leave-pool' ? 10 : 1);
          await tester.pumpWidget(const SizedBox());
          for (final item in pending) {
            item.reply.complete(Delay(name: item.params.proxyName, url: item.params.testUrl,
              value: scenario == 'leave-retry' ? -1 : 120));
          }
        }
        if (scenario == 'dispose-owner') {
          expect(calls, 1);
          await tester.pumpWidget(const SizedBox());
          container.dispose();
          ownerDisposed = true;
          pending.single.reply.complete(const Delay(name: 'node-0', url: _url, value: -1));
        }
        await flight;
        // Reads after the widget leaves use Riverpod's zero-delay disposal
        // scheduler; allow that normal scheduling turn before checking teardown.
        await tester.pump(const Duration(milliseconds: 1));
        if (!ownerDisposed) expect(container.read(xbMeasuringNodesProvider), isEmpty);
        if (ownerDisposed) {
          expect(failure, isNull);
          expect(calls, 1);
        } else if (scenario.startsWith('leave-')) {
          expect(failure, isNull, reason: 'production pooled tasks must not read a disposed WidgetRef');
          expect(calls, scenario == 'leave-pool' ? 11 : 2);
        } else {
          expect(failure, isNull);
          expect(calls, scenario.startsWith('old-') ? 3 : scenario == 'fresh-control' ? 2 : 1);
          expect(container.read(delayProvider(proxyName: 'node-0', testUrl: _url)),
            scenario == 'fresh-control' || scenario.startsWith('single-') ? 120 : -1);
        }
      });
    }
  }
}
