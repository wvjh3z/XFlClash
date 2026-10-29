import 'dart:async';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/providers/exit_ip_provider.dart';
import 'package:fl_clash/xboard/services/exit_ip_probe.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_ip_card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Route extends RouteTracker {
  @override
  RouteState build() => const RouteState(); // Never live: direct lookup must still work.
  @override
  void attach() {}
  @override
  void detach() {}
  void hostChanged() => state = state.copyWith(hostEpoch: state.hostEpoch + 1);
  void firstSync() =>
      applySnapshot(const RouteSnapshot(coreEpoch: 1, routeVersion: 1));
  void repeatSnapshot() => applySnapshot(
    RouteSnapshot(coreEpoch: state.coreEpoch, routeVersion: state.routeVersion),
  );
  void advanceRoute() =>
      state = state.copyWith(routeVersion: state.routeVersion + 1);
}

class _Probe extends XbExitIpProbe {
  final answer = Completer<XbExitIpResult?>();
  bool cancelled = false;
  @override
  Future<XbExitIpResult?> run() => answer.future;
  @override
  void cancel() {
    cancelled = true;
    super.cancel();
  }
}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      testWidgets(
        '$brand $platform late route revalidation keeps a labelled last IP',
        (tester) async {
          final connected = StateProvider<bool>((ref) => false);
          final suspended = StateProvider<bool>((ref) => false);
          final visible = StateProvider<bool>((ref) => true);
          final mode = StateProvider<Mode>((ref) => Mode.rule);
          final probes = <_Probe>[];
          final container = ProviderContainer(
            overrides: [
              routeTrackerProvider.overrideWith(_Route.new),
              isStartProvider.overrideWith((ref) => ref.watch(connected)),
              suspendProvider.overrideWith((ref) => ref.watch(suspended)),
              appVisibleProvider.overrideWithBuild(
                (ref, _) => ref.watch(visible),
              ),
              patchClashConfigProvider.overrideWithBuild(
                (ref, _) => PatchClashConfig(mode: ref.watch(mode)),
              ),
              selectedMapProvider.overrideWith((ref) => {}),
              xbExitIpProbeFactoryProvider.overrideWithValue(() {
                final p = _Probe();
                probes.add(p);
                return p;
              }),
            ],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: ThemeData(
                  platform: platform,
                  splashFactory: NoSplash.splashFactory,
                ),
                home: const Scaffold(body: XbIpCard()),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          probes.last.answer.complete(
            const XbExitIpResult('203.0.113.1', 'HK'),
          );
          await tester.pump();
          final route = container.read(routeTrackerProvider.notifier) as _Route;
          // Actual applySnapshot changes hostEpoch on first synchronization.
          route.firstSync();
          await tester.pump();
          expect(find.text('203.0.113.1'), findsOneWidget);
          expect(find.textContaining('上次结果，复核中'), findsOneWidget);
          expect(find.text('检测中…'), findsNothing);
          await tester.pump(const Duration(milliseconds: 300));
          probes.last.answer.complete(
            const XbExitIpResult('203.0.113.1', 'HK'),
          );
          await tester.pump();
          final count = probes.length;
          route.repeatSnapshot();
          await tester.pump(const Duration(seconds: 2));
          expect(probes.length, count);
          // A late route version (recording ~18s) must not blank the IP.
          route.advanceRoute();
          await tester.pump();
          expect(find.text('203.0.113.1'), findsOneWidget);
          expect(find.textContaining('上次结果，复核中'), findsOneWidget);
          expect(find.text('检测中…'), findsNothing);
          await tester.pump(const Duration(milliseconds: 300));
          final stale = probes.last;
          route.advanceRoute();
          await tester.pump();
          expect(stale.cancelled, isTrue);
          await tester.pump(const Duration(milliseconds: 300));
          stale.answer.complete(const XbExitIpResult('203.0.113.99', 'US'));
          await tester.pump();
          expect(find.text('203.0.113.99'), findsNothing);
          probes.last.answer.complete(
            const XbExitIpResult('203.0.113.2', 'JP'),
          );
          await tester.pump();
          expect(find.text('203.0.113.2'), findsOneWidget);
          expect(find.textContaining('上次结果'), findsNothing);
          // Revalidation failure cannot present the retained value as fresh.
          route.advanceRoute();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          probes.last.answer.completeError(Exception('probe failure'));
          await tester.pump();
          expect(find.text('203.0.113.2'), findsOneWidget);
          expect(find.textContaining('上次结果，复核失败'), findsOneWidget);
          await tester.tap(find.byType(IconButton));
          await tester.pump();
          expect(find.text('检测中…'), findsOneWidget);
          expect(find.text('203.0.113.2'), findsNothing);
          probes.last.answer.complete(
            const XbExitIpResult('203.0.113.3', 'HK'),
          );
          await tester.pump();
          // Explicit changes still invalidate old results, including pause.
          for (final action in [
            route.hostChanged,
            () => container.read(connected.notifier).state = true,
            () => container.read(suspended.notifier).state = true,
            () => container.read(suspended.notifier).state = false,
            () => container.read(mode.notifier).state = Mode.global,
          ]) {
            action();
            await tester.pump();
            expect(find.text('检测中…'), findsOneWidget);
            expect(find.textContaining('上次结果'), findsNothing);
            await tester.pump(const Duration(milliseconds: 300));
            probes.last.answer.complete(
              const XbExitIpResult('203.0.113.3', 'HK'),
            );
            await tester.pump();
          }
          // Background/resume cancels a revalidation and isolates its answer.
          route.advanceRoute();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          final hidden = probes.last;
          container.read(visible.notifier).state = false;
          await tester.pump();
          expect(hidden.cancelled, isTrue);
          hidden.answer.complete(const XbExitIpResult('203.0.113.99', 'US'));
          await tester.pump();
          container.read(visible.notifier).state = true;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          probes.last.answer.complete(
            const XbExitIpResult('203.0.113.4', 'HK'),
          );
          await tester.pump();
          expect(find.text('203.0.113.4'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        },
      );
      testWidgets(
        '$brand $platform manual refresh and route changes isolate stale IP',
        (tester) async {
          final connected = StateProvider<bool>((ref) => false);
          final mode = StateProvider<Mode>((ref) => Mode.rule);
          final picks = StateProvider<Map<String, String>>((ref) => {});
          final visible = StateProvider<bool>((ref) => true);
          final probes = <_Probe>[];
          late ProviderContainer container;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                routeTrackerProvider.overrideWith(_Route.new),
                isStartProvider.overrideWith((ref) => ref.watch(connected)),
                suspendProvider.overrideWith((ref) => false),
                appVisibleProvider.overrideWithBuild(
                  (ref, _) => ref.watch(visible),
                ),
                patchClashConfigProvider.overrideWithBuild(
                  (ref, _) => PatchClashConfig(mode: ref.watch(mode)),
                ),
                selectedMapProvider.overrideWith((ref) => ref.watch(picks)),
                xbExitIpProbeFactoryProvider.overrideWithValue(() {
                  final p = _Probe();
                  probes.add(p);
                  return p;
                }),
              ],
              child: MaterialApp(
                theme: ThemeData(
                  platform: platform,
                  splashFactory: NoSplash.splashFactory,
                ),
                home: Builder(
                  builder: (context) {
                    container = ProviderScope.containerOf(context);
                    return const Scaffold(body: XbIpCard());
                  },
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(probes.length, 1);
          expect(find.text('检测中…'), findsOneWidget);
          probes.last.answer.complete(
            const XbExitIpResult('203.0.113.1', 'CN'),
          );
          await tester.pump();
          expect(find.text('203.0.113.1'), findsOneWidget);
          await tester.tap(find.byType(IconButton));
          await tester.pump();
          expect(find.text('检测中…'), findsOneWidget);
          expect(find.text('203.0.113.1'), findsNothing);
          final old = probes.last;
          container.read(connected.notifier).state = true;
          await tester.pump();
          expect(old.cancelled, isTrue);
          await tester.pump(const Duration(milliseconds: 300));
          old.answer.complete(const XbExitIpResult('203.0.113.9', 'US'));
          await tester.pump();
          expect(find.text('203.0.113.9'), findsNothing);
          probes.last.answer.complete(
            const XbExitIpResult('203.0.113.2', 'HK'),
          );
          await tester.pump();
          expect(find.text('203.0.113.2'), findsOneWidget);
          for (final action in [
            () => container.read(mode.notifier).state = Mode.global,
            () => container.read(picks.notifier).state = {'GLOBAL': 'new-node'},
            () => container.read(connected.notifier).state = false,
          ]) {
            final count = probes.length;
            action();
            await tester.pump();
            expect(find.text('检测中…'), findsOneWidget);
            await tester.pump(const Duration(milliseconds: 300));
            expect(probes.length, count + 1);
            probes.last.answer.complete(null);
            await tester.pump();
            expect(find.text('检测失败'), findsOneWidget);
          }
          final stableCount = probes.length;
          container.read(picks.notifier).state = {'GLOBAL': 'new-node'};
          await tester.pump(const Duration(milliseconds: 500));
          expect(
            probes.length,
            stableCount,
          ); // Equal selections are not a route change.
          await tester.tap(find.byType(IconButton));
          await tester.pump();
          final pending = probes.last;
          container.read(visible.notifier).state = false;
          await tester.pump();
          expect(pending.cancelled, isTrue);
          pending.answer.complete(const XbExitIpResult('203.0.113.7', 'JP'));
          await tester.pump();
          expect(find.text('203.0.113.7'), findsNothing);
          container.read(visible.notifier).state = true;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          final closing = probes.last;
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          expect(closing.cancelled, isTrue);
          closing.answer.complete(const XbExitIpResult('203.0.113.8', 'JP'));
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
