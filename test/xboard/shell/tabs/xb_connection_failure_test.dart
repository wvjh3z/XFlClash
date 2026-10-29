import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';

class _Setup extends SetupAction {
  Future<bool> Function() result = () async => true;
  final calls = <({bool running, bool initialize})>[];
  @override
  void build() {}
  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) {
    calls.add((running: running, initialize: initialize));
    return result();
  }
}

class _Nodes extends XbNodesAdapter {
  int measured = 0;
  @override
  Future<void> measureCurrentNodeBest(
    WidgetRef ref, {
    String? explicitNode,
    int rounds = 3,
  }) async {
    measured++;
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
      for (final started in [false, true]) {
        for (final throws in [false, true]) {
          testWidgets(
            '$brand $platform running=$started throws=$throws failure and retry',
            (tester) async {
              final setup = _Setup();
              final nodes = _Nodes();
              final result = Completer<bool>();
              setup.result = () => result.future;
              final container = ProviderContainer(
                overrides: [
                  setupActionProvider.overrideWith(() => setup),
                  isStartProvider.overrideWith((ref) => started),
                  initProvider.overrideWithBuild((ref, notifier) => false),
                  xbNodesAdapterProvider.overrideWithValue(nodes),
                ],
              );
              addTearDown(container.dispose);
              container.read(bootstrapReadyProvider.notifier).set(true);
              container.read(coreStatusProvider.notifier).value =
                  CoreStatus.connected;
              await tester.pumpWidget(
                UncontrolledProviderScope(
                  container: container,
                  child: MaterialApp(
                    theme: ThemeData(
                      platform: platform,
                      colorSchemeSeed: brand == 'brand_a'
                          ? Colors.red
                          : Colors.orange,
                    ),
                    home: const Scaffold(body: XbConnectOrb()),
                  ),
                ),
              );
              await tester.tap(find.byType(XbConnectOrb));
              await tester.pump();
              expect(nodes.measured, 0);
              expect(setup.calls.single, (
                running: !started,
                initialize: !started,
              ));
              if (throws) {
                result.completeError(StateError('private native error'));
              } else {
                result.complete(false);
              }
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 250));
              expect(tester.takeException(), isNull);
              expect(
                find.textContaining(started ? '断开失败' : '连接失败'),
                findsOneWidget,
              );
              expect(find.textContaining('private native error'), findsNothing);
              expect(nodes.measured, 0);
              await tester.pump(const Duration(seconds: 3));
              setup.result = () async => true;
              await tester.tap(find.byType(XbConnectOrb));
              await tester.pump();
              expect(setup.calls, hasLength(2));
              expect(nodes.measured, started ? 0 : 1);
              expect(tester.takeException(), isNull);
              await tester.pump(const Duration(seconds: 3));
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
  testWidgets(
    'late failed connect cannot override newer successful disconnect',
    (tester) async {
      var started = false;
      final setup = _Setup();
      final first = Completer<bool>();
      setup.result = () => first.future;
      final nodes = _Nodes();
      final container = ProviderContainer(
        overrides: [
          setupActionProvider.overrideWith(() => setup),
          isStartProvider.overrideWith((ref) => started),
          initProvider.overrideWithBuild((ref, notifier) => true),
          xbNodesAdapterProvider.overrideWithValue(nodes),
        ],
      );
      addTearDown(container.dispose);
      container.read(bootstrapReadyProvider.notifier).set(true);
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: XbConnectOrb())),
        ),
      );
      await tester.tap(find.byType(XbConnectOrb));
      started = true;
      container.invalidate(isStartProvider);
      await tester.pump(const Duration(seconds: 1));
      setup.result = () async => true;
      await tester.tap(find.byType(XbConnectOrb));
      await tester.pump();
      first.completeError(StateError('superseded'));
      await tester.pump();
      expect(setup.calls.map((c) => c.running), [true, false]);
      expect(find.textContaining('失败'), findsNothing);
      expect(nodes.measured, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final fails in [false, true]) {
    testWidgets('disposed while operation pending, fails=$fails', (
      tester,
    ) async {
      final setup = _Setup();
      final result = Completer<bool>();
      setup.result = () => result.future;
      final nodes = _Nodes();
      final container = ProviderContainer(
        overrides: [
          setupActionProvider.overrideWith(() => setup),
          isStartProvider.overrideWith((ref) => false),
          initProvider.overrideWithBuild((ref, notifier) => true),
          xbNodesAdapterProvider.overrideWithValue(nodes),
        ],
      );
      addTearDown(container.dispose);
      container.read(bootstrapReadyProvider.notifier).set(true);
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: XbConnectOrb())),
        ),
      );
      await tester.tap(find.byType(XbConnectOrb));
      await tester.pumpWidget(const SizedBox());
      if (fails) {
        result.completeError(StateError('late'));
      } else {
        result.complete(true);
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(nodes.measured, 0);
    });
  }
}
