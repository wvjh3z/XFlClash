import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/nodes_tab.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/xb_node_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _SignedIn extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

void main() {
  for (final brand in ['OmoFly', 'Daishu']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      testWidgets(
        '$brand $platform follows upstream global visibility and entry',
        (tester) async {
          final desktop = platform != TargetPlatform.android;
          tester.view.physicalSize = desktop
              ? const Size(1280, 900)
              : const Size(440, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final mode = StateProvider<Mode>((ref) => Mode.global);
          final business = '$brand Select';
          final groups = [
            Group(
              name: business,
              type: GroupType.Selector,
              hidden: false,
              now: 'node-a',
              all: const [Proxy(name: 'node-a', type: 'ss')],
            ),
            const Group(
              name: 'GLOBAL',
              type: GroupType.Selector,
              hidden: true,
              now: 'node-b',
              all: [Proxy(name: 'node-b', type: 'ss')],
            ),
            const Group(
              name: 'Hidden',
              type: GroupType.Selector,
              hidden: true,
              now: 'node-c',
              all: [Proxy(name: 'node-c', type: 'ss')],
            ),
          ];
          final sourceGroups = StateProvider<List<Group>>((ref) => groups);
          late ProviderContainer container;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authStateProvider.overrideWith(_SignedIn.new),
                userProfileProvider.overrideWith(
                  (ref) async => const XbDomainSubscription(
                    email: 'fixture@example.test',
                    uuid: 'fixture',
                    totalBytes: 1000,
                    usedBytes: 0,
                    planId: 1,
                  ),
                ),
                groupsProvider.overrideWithBuild(
                  (ref, _) => ref.watch(sourceGroups),
                ),
                patchClashConfigProvider.overrideWithBuild(
                  (ref, _) => PatchClashConfig(mode: ref.watch(mode)),
                ),
                // Use upstream's actual visibility projection, without touching DB/core.
                proxiesTabStateProvider.overrideWith(
                  (ref) => ProxiesTabState(
                    groups: ref.watch(currentGroupsStateProvider).value,
                    currentGroupName: 'GLOBAL',
                    proxyCardType: ProxyCardType.standard,
                  ),
                ),
                for (final g in groups) ...[
                  selectedProxyNameProvider(g.name).overrideWithValue(g.now),
                  proxyNameProvider(g.name).overrideWithValue(null),
                  for (final p in g.all)
                    delayProvider(
                      proxyName: p.name,
                      testUrl: g.testUrl,
                    ).overrideWithValue(48),
                ],
              ],
              child: MaterialApp(
                theme: ThemeData(platform: platform),
                home: Builder(
                  builder: (context) {
                    container = ProviderScope.containerOf(context);
                    return const Scaffold(body: NodesTab());
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          String active() =>
              tester.widget<XbNodeGroup>(find.byType(XbNodeGroup)).group.name;
          expect(
            active(),
            'GLOBAL',
          ); // Initial entry, even though business is first.
          container.read(mode.notifier).state = Mode.rule;
          await tester.pumpAndSettle();
          expect(active(), business);
          expect(find.text('GLOBAL', findRichText: true), findsNothing);
          expect(find.text('Hidden', findRichText: true), findsNothing);
          container.read(mode.notifier).state = Mode.global;
          await tester.pumpAndSettle();
          expect(active(), 'GLOBAL');
          expect(find.text('当前无可用线路'), findsNothing);
          expect(find.text('Hidden', findRichText: true), findsWidgets);
          await tester.tap(find.text(business, findRichText: true).first);
          await tester.pumpAndSettle();
          expect(
            active(),
            business,
          ); // Browsing other groups remains available.
          container.read(mode.notifier).state = Mode.rule;
          await tester.pumpAndSettle();
          expect(active(), business);
          expect(find.text('Hidden', findRichText: true), findsNothing);
          container.read(mode.notifier).state = Mode.global;
          await tester.pumpAndSettle();
          expect(
            active(),
            'GLOBAL',
          ); // Mode change resets entry, ordinary rebuild doesn't.
          await tester.tap(find.text(business, findRichText: true).first);
          await tester.pumpAndSettle();
          container.read(sourceGroups.notifier).state = [groups[2], groups[1]];
          await tester.pumpAndSettle();
          expect(
            active(),
            'GLOBAL',
          ); // Refresh removed the browsed group; prefer GLOBAL.
          container.read(sourceGroups.notifier).state = [
            groups[1].copyWith(hidden: false),
            groups[0],
          ];
          container.read(mode.notifier).state = Mode.rule;
          await tester.pumpAndSettle();
          expect(
            find.text('GLOBAL', findRichText: true),
            findsWidgets,
          ); // Explicit visible GLOBAL follows upstream too.
          container.read(mode.notifier).state = Mode.direct;
          await tester.pumpAndSettle();
          expect(find.byType(XbNodeGroup), findsNothing);
        },
      );
    }
  }
}
