import 'dart:async';
import 'package:fl_clash/models/models.dart';
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
  @override
  void startCheck(WidgetRef ref) {}
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

// Keep the real setRunning/_run/_stop/rollback. Only the native boundary is fake.
class _NativeSetup extends SetupAction {
  final stop = Completer<bool>();
  final entered = Completer<void>();
  @override
  Future<bool> setCoreRunning(bool running) {
    if (running) return Future.value(true);
    if (!entered.isCompleted) entered.complete();
    return stop.future;
  }

  @override
  void resetCoreTraffic() {}
  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    await preloadInvoke?.call();
    return true;
  }
}

void bindBrand(String brand) => XboardConfig.bind(
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

void main() {
  tearDown(XboardConfig.resetForTest);
  for (final brand in ['brand_a', 'brand_b']) {
    for (final desktop in [false, true]) {
      for (final scenario in [
        'stopped-blocked',
        'stopped-allowed',
        'started',
        'gate-changes-state',
      ]) {
        testWidgets('$brand desktop=$desktop stale frame $scenario', (
          tester,
        ) async {
          bindBrand(brand);
          var running = scenario != 'started';
          var gated = 0;
          final setup = _Setup();
          final c = ProviderContainer(
            overrides: [
              isStartProvider.overrideWith((ref) => running),
              excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
              setupActionProvider.overrideWith(() => setup),
              xbNetworkAdapterProvider.overrideWithValue(_Network()),
              xbNodesAdapterProvider.overrideWithValue(_Nodes()),
            ],
          );
          addTearDown(c.dispose);
          c.read(bootstrapReadyProvider.notifier).set(true);
          c.read(initProvider.notifier).value = true;
          c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
          c.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: MaterialApp(
                home: Scaffold(
                  body: Center(
                    child: XbConnectOrb(
                      statusBelow: desktop,
                      onBlocked: () {
                        gated++;
                        if (scenario == 'gate-changes-state') {
                          running = true;
                          c.invalidate(isStartProvider);
                        }
                        return scenario == 'stopped-allowed' ||
                                scenario == 'gate-changes-state'
                            ? null
                            : XbConnectBlock.notLoggedIn;
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(find.text(running ? '已暂停' : '未连接'), findsOneWidget);
          running = !running;
          c.invalidate(isStartProvider);
          // No pump: native state changed while the last rendered frame is stale.
          await tester.tap(find.byType(XbConnectOrb));
          await tester.pump();
          expect(gated, scenario == 'started' ? 0 : 1);
          expect(
            setup.calls,
            scenario == 'stopped-blocked' ? <bool>[] : [scenario != 'started'],
          );
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        });
      }
      for (final failsWithException in [false, true]) {
        testWidgets(
          '$brand desktop=$desktop real stop exception=$failsWithException',
          (tester) async {
            bindBrand(brand);
            final setup = _NativeSetup();
            final c = ProviderContainer(
              overrides: [
                setupActionProvider.overrideWith(() => setup),
                appVisibleProvider.overrideWithBuild((ref, notifier) => false),
                excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
                vpnOptionsProvider.overrideWith(
                  (ref) async => const VpnOptions(
                    enable: false,
                    port: 0,
                    ipv6: false,
                    dnsHijacking: false,
                    accessControlProps: AccessControlProps(),
                    allowBypass: false,
                    systemProxy: false,
                    bypassDomain: [],
                    stack: 'mixed',
                  ),
                ),
                xbNetworkAdapterProvider.overrideWithValue(_Network()),
                xbNodesAdapterProvider.overrideWithValue(_Nodes()),
              ],
            );
            addTearDown(c.dispose);
            c.read(bootstrapReadyProvider.notifier).set(true);
            c.read(initProvider.notifier).value = true;
            c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
            c.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';
            // Real startup records its run intent; excluded SSID skips native start.
            await c
                .read(setupActionProvider.notifier)
                .setRunning(true, initialize: true);
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: c,
                child: MaterialApp(
                  home: Scaffold(
                    body: Center(child: XbConnectOrb(statusBelow: desktop)),
                  ),
                ),
              ),
            );
            expect(find.text('已暂停'), findsOneWidget);
            await tester.tap(find.byType(XbConnectOrb));
            await tester.pump();
            expect(setup.entered.isCompleted, isTrue);
            expect(c.read(isStartProvider), isFalse);
            if (failsWithException) {
              setup.stop.completeError(StateError('native stop failure'));
            } else {
              setup.stop.complete(false);
            }
            await tester.pump();
            // The async native result schedules provider/UI and toast frames.
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 250));
            expect(c.read(isStartProvider), failsWithException);
            expect(
              find.text(failsWithException ? '已暂停' : '未连接'),
              findsOneWidget,
            );
            expect(find.textContaining('断开失败'), findsOneWidget);
            c.read(currentSSIDProvider.notifier).value = 'Other Wi-Fi';
            await tester.pump();
            expect(
              find.text(failsWithException ? '已连接' : '未连接'),
              findsOneWidget,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 3));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
