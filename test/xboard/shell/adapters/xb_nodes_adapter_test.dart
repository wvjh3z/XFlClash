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

  group('runBatchedConcurrent 进度计数（修「测速中 N/M」横跳）', () {
    test('完成计数单调递增且最终到 total（批内并发、批间串行）', () async {
      final items = List.generate(25, (i) => i);
      final seen = <int>[];
      var done = 0;
      await runBatchedConcurrent<int>(
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
      await runBatchedConcurrent<int>(
        [1, 2, 3],
        0,
        (_) async => done++,
      );
      expect(done, 3);
    });
  });
}
