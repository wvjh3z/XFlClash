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
}
