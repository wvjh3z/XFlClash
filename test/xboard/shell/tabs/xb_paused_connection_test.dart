import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_network_adapter.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';

class _Setup extends SetupAction {
  bool accepted = true;
  final calls = <bool>[];
  @override
  void build() {}
  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    calls.add(running);
    return accepted;
  }
}

class _Network extends XbNetworkAdapter {
}

class _Nodes extends XbNodesAdapter {
  int measurements = 0;
  @override
  Future<void> measureCurrentNodeBest(
    WidgetRef ref, {
    String? explicitNode,
    int rounds = 3,
  }) async {
    measurements++;
  }
}

void main() {
  tearDown(XboardConfig.resetForTest);
  for (final brand in ['brand_a', 'brand_b']) {
    for (final desktop in [false, true]) {
      testWidgets('$brand desktop=$desktop pause, restore and stop semantics', (
        tester,
      ) async {
        XboardConfig.bind(
          XboardConfig(
            subscribeUserAgent: 'test',
            devApiEndpoint: 'https://api.example.invalid',
            devSubscriptionEndpoint: 'https://sub.example.invalid',
            flavorId: brand,
            formA: true,
            kIsTest: true,
            debug: false,
          ),
        );
        var running = true;
        var blocked = 0;
        final setup = _Setup();
        final nodes = _Nodes();
        final c = ProviderContainer(
          overrides: [
            isStartProvider.overrideWith((ref) => running),
            excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
            setupActionProvider.overrideWith(() => setup),
            xbNetworkAdapterProvider.overrideWithValue(_Network()),
            xbNodesAdapterProvider.overrideWithValue(nodes),
          ],
        );
        addTearDown(c.dispose);
        c.read(bootstrapReadyProvider.notifier).set(true);
        c.read(initProvider.notifier).value = true;
        c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: XbConnectOrb(
                    statusBelow: desktop,
                    onBlocked: () {
                      blocked++;
                      return XbConnectBlock.noNodes;
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('已连接'), findsOneWidget);
        c.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';
        await tester.pump();
        expect(c.read(suspendProvider), isTrue);
        expect(find.text('已暂停'), findsOneWidget);
        expect(find.text('离开此 Wi-Fi 后自动恢复'), findsOneWidget);
        expect(find.text('数据已加密保护'), findsNothing);
        expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
        expect(setup.calls, isEmpty);
        // Core initialization has priority; it must not claim a settled pause.
        c.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
        await tester.pump();
        expect(find.text('连接中'), findsOneWidget);
        c.read(bootstrapReadyProvider.notifier).set(false);
        await tester.pump();
        expect(find.text('准备中'), findsOneWidget);
        c.read(bootstrapReadyProvider.notifier).set(true);
        c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
        c.read(currentSSIDProvider.notifier).value = 'Other Wi-Fi';
        await tester.pump();
        expect(find.text('已连接'), findsOneWidget);
        expect(
          setup.calls,
          isEmpty,
        ); // Rendering never changes the upstream run.
        c.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';
        await tester.pump();
        setup.accepted = false;
        await tester.tap(find.byType(XbConnectOrb));
        await tester.pump();
        expect(setup.calls, [false]);
        expect(blocked, 0); // Pause's stop must bypass login/subscribe gates.
        expect(find.text('已暂停'), findsOneWidget);
        expect(find.textContaining('断开失败'), findsOneWidget);
        expect(nodes.measurements, 0);
        await tester.pump(const Duration(seconds: 3));
        setup.accepted = true;
        await tester.tap(find.byType(XbConnectOrb));
        await tester.pump();
        expect(setup.calls, [false, false]);
        running =
            false; // Native stop confirmation, not an optimistic UI reset.
        c.invalidate(isStartProvider);
        await tester.pump();
        expect(c.read(suspendProvider), isTrue);
        expect(find.text('未连接'), findsOneWidget);
        c.read(currentSSIDProvider.notifier).value = 'Other Wi-Fi';
        await tester.pump();
        expect(find.text('未连接'), findsOneWidget);
        expect(setup.calls, [false, false]);
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.byType(XbConnectOrb));
        await tester.pump();
        expect(blocked, 1); // A later fresh connect uses the normal gate again.
        expect(setup.calls, [false, false]);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      });
    }
  }
}
