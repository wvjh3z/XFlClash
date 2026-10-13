/// 分组测速的完整重试状态：中间失败不显示超时，整轮结束后发布最终显示。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show Delay, Group, Proxy, ProxiesTabState;
import 'package:fl_clash/providers/app.dart'
    show delayDataSourceProvider, groupsProvider;
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/xb_node_group.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbSpinner;

const _url = 'https://latency.test/generate_204';

class _ControlledAdapter extends XbNodesAdapter {
  _ControlledAdapter(this.container);

  final ProviderContainer container;
  final attempts = <({String name, Completer<int> result})>[];

  void emitDelay(String name, int value) {
    container
        .read(delayDataSourceProvider.notifier)
        .setDelay(Delay(url: _url, name: name, value: value));
  }

  @override
  Future<void> testNode(
    WidgetRef ref, {
    required String proxyName,
    required String type,
    String? testUrl,
  }) async {
    final result = Completer<int>();
    attempts.add((name: proxyName, result: result));
    emitDelay(proxyName, 0);
    emitDelay(proxyName, await result.future);
  }
}

Future<
  ({ProviderContainer container, _ControlledAdapter adapter, WidgetRef ref})
>
pumpRetryGroup(
  WidgetTester tester, {
  int nodeCount = 1,
  bool secondGroup = false,
}) async {
  final nodes = List.generate(
    nodeCount,
    (i) => Proxy(name: 'HK${i + 1}', type: 'ss'),
  );
  final group = Group(
    type: GroupType.Selector,
    name: 'HK',
    all: nodes,
    testUrl: _url,
  );
  final groups = [
    group,
    if (secondGroup)
      const Group(
        type: GroupType.Selector,
        name: 'JP',
        all: [Proxy(name: 'JP1', type: 'ss')],
        testUrl: _url,
      ),
  ];
  late _ControlledAdapter adapter;
  final container = ProviderContainer(
    overrides: [
      xbNodesAdapterProvider.overrideWith((ref) => adapter),
      groupsProvider.overrideWithBuild((ref, _) => groups),
      proxiesTabStateProvider.overrideWith(
        (ref) => ProxiesTabState(
          groups: groups,
          currentGroupName: 'HK',
          proxyCardType: ProxyCardType.expand,
          columns: 1,
        ),
      ),
      realTestUrlProvider(_url).overrideWithValue(_url),
      selectedMapProvider.overrideWith((ref) => const {}),
      selectedProxyNameProvider('HK').overrideWithValue(''),
      proxyNameProvider('HK').overrideWithValue(null),
    ],
  );
  adapter = _ControlledAdapter(container);
  addTearDown(container.dispose);
  late WidgetRef widgetRef;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          widgetRef = ref;
          return MaterialApp(
            home: Scaffold(
              body: XbNodeGroup(
                group: XbGroupSummary(
                  name: 'HK',
                  nodeCount: nodeCount,
                  currentSelected: '',
                  isUrlTest: false,
                  kind: XbGroupKind.selector,
                  testUrl: _url,
                  nodes: [
                    for (final p in nodes)
                      XbNodeItem(name: p.name, type: p.type, testUrl: _url),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  return (container: container, adapter: adapter, ref: widgetRef);
}

void main() {
  for (final failures in [0, 1, 2]) {
    testWidgets('$failures 次超时后成功：整轮转圈，只显示最终延迟', (tester) async {
      final h = await pumpRetryGroup(tester);
      final progress = <(int, int)>[];
      final task = h.adapter.testGroupDelay(
        h.ref,
        'HK',
        onProgress: (done, total) {
          progress.add((done, total));
        },
      );
      await tester.pump();
      for (var i = 0; i < failures; i++) {
        // 模拟 onDelay 先推送 -1，桥接 Future 稍后才结束这一尝试。
        h.adapter.emitDelay('HK1', -1);
        await tester.pump();
        expect(
          h.container.read(delayProvider(proxyName: 'HK1', testUrl: _url)),
          -1,
        );
        expect(find.text('超时'), findsNothing);
        expect(find.byType(XbSpinner), findsOneWidget);
        h.adapter.attempts.last.result.complete(-1);
        await tester.pump();
        expect(find.text('超时'), findsNothing);
        expect(find.byType(XbSpinner), findsOneWidget);
        expect(h.container.read(xbMeasuringNodesProvider), {'HK1'});
        expect(progress, isEmpty);
      }
      h.adapter.emitDelay('HK1', 121);
      await tester.pump();
      expect(find.text('60 ms'), findsNothing);
      expect(find.byType(XbSpinner), findsOneWidget);
      h.adapter.attempts.last.result.complete(121);
      await tester.pump();
      await task;
      expect(h.adapter.attempts.length, failures + 1);
      expect(find.text('60 ms'), findsOneWidget);
      expect(find.text('超时'), findsNothing);
      expect(find.byType(XbSpinner), findsNothing);
      expect(
        h.container.read(delayProvider(proxyName: 'HK1', testUrl: _url)),
        121,
      );
      expect(h.container.read(xbMeasuringNodesProvider), isEmpty);
      expect(progress, [(1, 1)]);
    });
  }

  testWidgets('连续三次超时：第三次结束后才显示超时，进度只计一次', (tester) async {
    final h = await pumpRetryGroup(tester);
    final progress = <(int, int)>[];
    final task = h.adapter.testGroupDelay(
      h.ref,
      'HK',
      onProgress: (done, total) {
        progress.add((done, total));
      },
    );
    for (var i = 0; i < 3; i++) {
      h.adapter.emitDelay('HK1', -1);
      await tester.pump();
      expect(find.text('超时'), findsNothing);
      expect(find.byType(XbSpinner), findsOneWidget);
      h.adapter.attempts.last.result.complete(-1);
      await tester.pump();
      if (i < 2) expect(progress, isEmpty);
    }
    await task;
    expect(h.adapter.attempts.length, 3);
    expect(find.text('超时'), findsOneWidget);
    expect(find.byType(XbSpinner), findsNothing);
    expect(
      h.container.read(delayProvider(proxyName: 'HK1', testUrl: _url)),
      -1,
    );
    expect(h.container.read(xbMeasuringNodesProvider), isEmpty);
    expect(progress, [(1, 1)]);
  });

  testWidgets('首页与分组同时测速：一轮结束不会提前显示结果', (tester) async {
    final h = await pumpRetryGroup(tester);
    final measuring = h.container.read(xbMeasuringNodesProvider.notifier);
    measuring.start('HK1'); // 模拟首页仍在测同名节点。
    final task = h.adapter.testGroupDelay(h.ref, 'HK');
    h.adapter.attempts.last.result.complete(120);
    await tester.pump();
    await task;
    expect(find.text('60 ms'), findsNothing);
    expect(find.byType(XbSpinner), findsOneWidget);
    measuring.finish('HK1');
    await tester.pump();
    expect(find.text('60 ms'), findsOneWidget);
    expect(find.byType(XbSpinner), findsNothing);
  });

  testWidgets('离开页面后重试仍完成并解除测速态', (tester) async {
    final h = await pumpRetryGroup(tester);
    final task = h.adapter.testGroupDelay(h.ref, 'HK');
    await tester.pumpWidget(const SizedBox());
    h.adapter.attempts.last.result.complete(-1);
    await tester.pump();
    h.adapter.attempts.last.result.complete(120);
    await tester.pump();
    await task;
    expect(h.adapter.attempts.length, 2);
    expect(h.container.read(xbMeasuringNodesProvider), isEmpty);
    expect(
      h.container.read(delayProvider(proxyName: 'HK1', testUrl: _url)),
      120,
    );
  });

  testWidgets('单次调用异常仍解除本轮测速标记', (tester) async {
    final h = await pumpRetryGroup(tester);
    final task = h.adapter.testGroupDelay(h.ref, 'HK');
    final assertion = expectLater(task, throwsStateError);
    h.adapter.attempts.last.result.completeError(StateError('test failure'));
    await tester.pump();
    await assertion;
    expect(h.container.read(xbMeasuringNodesProvider), isEmpty);
  });

  testWidgets('跨组刷新在离开页面后继续测试后续分组', (tester) async {
    final h = await pumpRetryGroup(tester, secondGroup: true);
    final task = h.adapter.refresh(h.ref);
    await tester.pumpWidget(const SizedBox());
    h.adapter.attempts.last.result.complete(120);
    await tester.pump();
    expect(h.adapter.attempts.map((a) => a.name), ['HK1', 'JP1']);
    h.adapter.attempts.last.result.complete(120);
    await tester.pump();
    await task;
    expect(h.container.read(xbMeasuringNodesProvider), isEmpty);
  });

  testWidgets('批量刷新共用重试状态，慢节点不阻塞并发池补位', (tester) async {
    final h = await pumpRetryGroup(tester, nodeCount: 11);
    final task = h.adapter.refresh(h.ref, groupName: 'HK');
    expect(h.adapter.attempts.length, 10);
    final first = List.of(h.adapter.attempts);
    first.first.result.complete(-1);
    first[1].result.complete(120);
    await tester.pump();
    expect(h.adapter.attempts.length, 12); // HK1 重试、HK11 补位。
    expect(h.container.read(xbMeasuringNodesProvider), contains('HK1'));
    expect(h.container.read(xbMeasuringNodesProvider), contains('HK11'));
    expect(h.container.read(xbMeasuringNodesProvider), isNot(contains('HK2')));
    for (final attempt in h.adapter.attempts) {
      if (!attempt.result.isCompleted) attempt.result.complete(120);
    }
    await tester.pump();
    await task;
    expect(h.container.read(xbMeasuringNodesProvider), isEmpty);
  });
}
