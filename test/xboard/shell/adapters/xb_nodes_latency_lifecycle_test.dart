import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/home/home_latency_provider.dart';

class _Core extends Mock implements CoreHandlerInterface {}

class _Auth extends AuthStateNotifier {
  int revision = 1;
  @override
  AuthState build() => AuthState.authenticated;
  @override
  int get sessionRevision => revision;
}

class _Actions extends ProxiesAction {
  final writes = <Delay>[];
  bool fail = false;
  @override
  void build() {}
  @override
  void setDelay(Delay delay) {
    if (fail) {
      throw StateError('controlled write failure');
    }
    writes.add(delay);
  }
}

class _Adapter extends XbNodesAdapter {
  @override
  ({String proxyName, String testUrl})? resolveMeasureTarget(
    WidgetRef ref, {
    String? explicitNode,
  }) => (proxyName: explicitNode!, testUrl: 'https://example.invalid');
}

const url = 'https://example.invalid';
void main() {
  setUpAll(() => registerFallbackValue(Duration.zero));
  for (final brand in ['brand_a', 'brand_b']) {
    for (final scenario in [
      'newer',
      'old_failure',
      'disconnect',
      'pause',
      'account',
      'selection',
      'reset',
      'dispose_page',
      'dispose_container',
      'write_failure',
      'core_failure',
      'same_node',
      'success',
    ]) {
      testWidgets('$brand latency $scenario', (tester) async {
        var running = true;
        var suspended = false;
        var selected = <String, String>{'group': 'A'};
        final core = _Core();
        final auth = _Auth();
        final actions = _Actions();
        final a = Completer<Delay?>();
        final b = Completer<Delay?>();
        var callsA = 0;
        when(() => core.asyncTestDelay(any(), 'A', any())).thenAnswer((_) {
          callsA++;
          if (scenario == 'success' && callsA > 1) {
            return Future.value(
              Delay(url: url, name: 'A', value: callsA == 2 ? 50 : 80),
            );
          }
          return a.future;
        });
        when(
          () => core.asyncTestDelay(any(), 'B', any()),
        ).thenAnswer((_) => b.future);
        final c = ProviderContainer(
          overrides: [
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            proxiesActionProvider.overrideWith(() => actions),
            authStateProvider.overrideWith(() => auth),
            isStartProvider.overrideWith((ref) => running),
            suspendProvider.overrideWith((ref) => suspended),
            selectedMapProvider.overrideWith((ref) => selected),
          ],
        );
        var disposed = false;
        addTearDown(() {
          if (!disposed) {
            c.dispose();
          }
        });
        late WidgetRef ref;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              theme: ThemeData(
                colorSchemeSeed: brand == 'brand_a'
                    ? Colors.red
                    : Colors.orange,
              ),
              home: Consumer(
                builder: (context, r, _) {
                  ref = r;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        final homeSubscription = c.listen(homeLatencyProvider, (_, _) {});
        addTearDown(homeSubscription.close);
        final adapter = _Adapter();
        final first = adapter.measureCurrentNodeBest(
          ref,
          explicitNode: 'A',
          rounds: 3,
        );
        expect(c.read(xbMeasuringNodesProvider), contains('A'));
        if (scenario == 'newer' ||
            scenario == 'old_failure' ||
            scenario == 'same_node') {
          final target = scenario == 'same_node' ? 'A' : 'B';
          if (target == 'A') {
            when(
              () => core.asyncTestDelay(any(), 'A', any()),
            ).thenAnswer((_) => b.future);
          }
          final second = adapter.measureCurrentNodeBest(
            ref,
            explicitNode: target,
            rounds: 1,
          );
          b.complete(Delay(url: url, name: target, value: 30));
          await tester.pump();
          await second;
          expect(c.read(homeLatencyProvider).ms, 30);
          if (target == 'A') {
            expect(c.read(xbMeasuringNodesProvider), contains('A'));
          }
        } else if (scenario == 'disconnect') {
          running = false;
          c.invalidate(isStartProvider);
          await tester.pump();
        } else if (scenario == 'pause') {
          suspended = true;
          c.invalidate(suspendProvider);
          await tester.pump();
        } else if (scenario == 'account') {
          auth.revision++; // Same authenticated enum, different session.
        } else if (scenario == 'selection') {
          selected = {'group': 'B'};
          c.invalidate(selectedMapProvider);
          await tester.pump();
        } else if (scenario == 'reset') {
          c.read(homeLatencyProvider.notifier).reset();
        } else if (scenario == 'dispose_page' ||
            scenario == 'dispose_container') {
          await tester.pumpWidget(const SizedBox());
          if (scenario == 'dispose_container') {
            c.dispose();
            disposed = true;
          }
        } else if (scenario == 'write_failure') {
          actions.fail = true;
        }
        if (scenario == 'old_failure' || scenario == 'core_failure') {
          a.completeError(StateError('late failure'));
        } else {
          a.complete(const Delay(url: url, name: 'A', value: 200));
        }
        await tester.pump();
        await first;
        expect(tester.takeException(), isNull);
        if (!disposed) {
          expect(c.read(xbMeasuringNodesProvider), isEmpty);
          final expected =
              ['newer', 'old_failure', 'same_node'].contains(scenario)
              ? 30
              : scenario == 'success'
              ? 50
              : null;
          expect(c.read(homeLatencyProvider).ms, expected);
          expect(c.read(homeLatencyProvider).measuring, isFalse);
          if (scenario == 'success') {
            expect(actions.writes.single.value, 50);
            verify(() => core.asyncTestDelay(url, 'A', any())).called(3);
          } else if (!['write_failure'].contains(scenario)) {
            verify(
              () => core.asyncTestDelay(url, 'A', any()),
            ).called(scenario == 'same_node' ? 2 : 1);
          }
        }
        await tester.pumpWidget(const SizedBox());
        if (!disposed) {
          c.dispose();
          disposed = true;
        }
        await tester.pump();
      });
    }
  }
}
