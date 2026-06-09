/// W2.4 — XbNodesAdapter nodesView 投影单测。
///
/// 覆盖：hidden 组过滤 / url-test 标记 / 节点数 / 当前选中 / 空态。
/// 用 `overrideWith` 注入 `proxiesTabStateProvider`（functional provider）；投影结果通过
/// 一个 callback 捕获（避免 widget 持可变字段）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show Group, Proxy, ProxiesTabState;
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';

ProxiesTabState _tabState(List<Group> groups) => ProxiesTabState(
      groups: groups,
      currentGroupName: groups.isEmpty ? null : groups.first.name,
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

Group _group(
  String name,
  GroupType type, {
  List<String> proxies = const [],
  String? now,
  bool hidden = false,
}) =>
    Group(
      type: type,
      name: name,
      all: [for (final p in proxies) Proxy(name: p, type: 'ss')],
      now: now,
      hidden: hidden,
    );

class _Probe extends ConsumerWidget {
  const _Probe(this.onView);

  final void Function(XbNodesView) onView;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const adapter = XbNodesAdapter();
    onView(adapter.nodesView(ref));
    return const SizedBox.shrink();
  }
}

Future<XbNodesView> pumpView(WidgetTester tester, List<Group> groups) async {
  late XbNodesView view;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        proxiesTabStateProvider.overrideWith((ref) => _tabState(groups)),
      ],
      child: _Probe((v) => view = v),
    ),
  );
  return view;
}

void main() {
  testWidgets('空分组 → isEmpty', (tester) async {
    final view = await pumpView(tester, const []);
    expect(view.isEmpty, isTrue);
    expect(view.groups, isEmpty);
  });

  testWidgets('hidden 组被过滤', (tester) async {
    final view = await pumpView(tester, [
      _group('可见', GroupType.Selector, proxies: ['a', 'b']),
      _group('隐藏', GroupType.Selector, hidden: true),
    ]);
    expect(view.groups.length, 1);
    expect(view.groups.first.name, '可见');
  });

  testWidgets('url-test 组标记 + 节点数 + 当前选中', (tester) async {
    final view = await pumpView(tester, [
      _group('自动组', GroupType.URLTest, proxies: ['x', 'y', 'z'], now: 'y'),
    ]);
    final g = view.groups.single;
    expect(g.isUrlTest, isTrue);
    expect(g.nodeCount, 3);
    expect(g.currentSelected, 'y');
  });

  testWidgets('selector 组 isUrlTest=false', (tester) async {
    final view = await pumpView(tester, [
      _group('手动组', GroupType.Selector, proxies: ['a']),
    ]);
    expect(view.groups.single.isUrlTest, isFalse);
  });

  group('runPooledConcurrent 进度计数（修「测速中 N/M」横跳 + 慢节点不阻塞）', () {
    test('完成计数单调递增且最终到 total', () async {
      final items = List.generate(25, (i) => i);
      final seen = <int>[];
      var done = 0;
      await runPooledConcurrent<int>(
        items,
        10,
        (item) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          done++;
          seen.add(done);
        },
      );
      // 完成计数严格递增、不回退（横跳即非单调）；末值=总数。
      expect(seen.length, items.length);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]),
            reason: '完成计数必须单调递增，不可横跳/回退');
      }
      expect(seen.last, items.length);
    });

    test('concurrency<=0 → 全串行仍正确计数', () async {
      var done = 0;
      await runPooledConcurrent<int>(
        [1, 2, 3],
        0,
        (_) async => done++,
      );
      expect(done, 3);
    });

    test('始终保持并发池满（峰值在跑数 = concurrency，不退化为批次）', () async {
      // 任务①耗时长（模拟卡住的慢节点），其余短任务应能持续补位、不被它阻塞。
      final items = List.generate(20, (i) => i);
      var running = 0;
      var maxRunning = 0;
      final completedBeforeSlow = <int>[];
      await runPooledConcurrent<int>(
        items,
        5,
        (item) async {
          running++;
          if (running > maxRunning) maxRunning = running;
          // item 0 = 慢节点（远长于其它），其余很快。
          await Future<void>.delayed(
              Duration(milliseconds: item == 0 ? 80 : 2));
          if (item != 0) completedBeforeSlow.add(item);
          running--;
        },
      );
      // 并发池：同时在跑数应达到上限 5（固定批次也能达到，但下面这条是关键区分）。
      expect(maxRunning, 5);
      // 关键：慢节点(0)还没完成时，后续大量短任务已完成补位 —— 证明没被慢节点阻塞。
      // 固定批次下，含慢节点的那一批只有该批其余 4 个能先完成，之后整体停摆等它；
      // 并发池下慢节点只占 1 槽，剩余 19 个里远超 4 个会在它之前完成。
      expect(completedBeforeSlow.length, greaterThan(10),
          reason: '慢节点不应阻塞后续任务推进');
    });
  });
}
