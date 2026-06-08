/// XbNodeGroup 进入定位：长列表注入假数据，断言选中节点滚动到视口尽量居中（靠边就近）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/xb_node_group.dart';

/// 构造 N 个节点的 selector 组（假数据）。
XbGroupSummary _group(int n, {required String selected}) {
  final nodes = [
    for (var i = 0; i < n; i++)
      XbNodeItem(name: '🇸🇬 节点 ${i.toString().padLeft(2, '0')}', type: 'ss'),
  ];
  return XbGroupSummary(
    name: '香港',
    nodeCount: n,
    currentSelected: selected,
    isUrlTest: false,
    kind: XbGroupKind.selector,
    nodes: nodes,
  );
}

Future<ScrollController> _pump(
  WidgetTester tester, {
  required XbGroupSummary group,
  required String scrollTo,
}) async {
  // 固定视口高度，使「居中」可断言。
  tester.view.physicalSize = const Size(390 * 3, 700 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final overrides = [
    selectedProxyNameProvider(group.name).overrideWithValue(group.currentSelected),
    for (final node in group.nodes)
      delayProvider(proxyName: node.name, testUrl: group.testUrl)
          .overrideWithValue(48),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Scaffold(
          body: XbNodeGroup(group: group, scrollToNode: scrollTo),
        ),
      ),
    ),
  );
  // 等定位动画（postFrame + animateTo 320ms）完成。
  await tester.pumpAndSettle();
  return tester
      .widget<ListView>(find.byType(ListView))
      .controller!;
}

/// 选中行中心相对视口顶部的偏移（用于断言是否居中）。
double _rowCenterInViewport(WidgetTester tester, String nodeName) {
  final rowFinder = find.ancestor(
    of: find.text(nodeName),
    matching: find.byType(Padding),
  ).first;
  final box = tester.renderObject<RenderBox>(rowFinder);
  final topLeft = box.localToGlobal(Offset.zero);
  return topLeft.dy + box.size.height / 2;
}

void main() {
  testWidgets('中部选中节点 → 滚动到视口尽量居中', (tester) async {
    final group = _group(40, selected: '🇸🇬 节点 20');
    final ctrl = await _pump(tester, group: group, scrollTo: '🇸🇬 节点 20');

    // 已发生滚动（不在顶部）。
    expect(ctrl.offset, greaterThan(0));
    // 选中行存在且可见。
    expect(find.text('🇸🇬 节点 20'), findsOneWidget);

    // 选中行中心应接近视口中央（容差 ±1.5 行高）。
    final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final center = _rowCenterInViewport(tester, '🇸🇬 节点 20');
    expect((center - screenH / 2).abs(), lessThan(90),
        reason: '中部节点应尽量居中，实测中心=$center 视口中心=${screenH / 2}');
  });

  testWidgets('靠顶选中节点（不强制居中）→ 不过度滚动，停在接近顶部', (tester) async {
    final group = _group(40, selected: '🇸🇬 节点 01');
    final ctrl = await _pump(tester, group: group, scrollTo: '🇸🇬 节点 01');
    // 第 2 个节点无法居中（上方不够），offset 应被 clamp 到接近 0。
    expect(ctrl.offset, lessThan(60),
        reason: '靠顶节点无法居中 → 就近停在顶部，offset≈0');
    expect(find.text('🇸🇬 节点 01'), findsOneWidget);
  });

  testWidgets('靠底选中节点（不强制居中）→ 停在最大滚动位置', (tester) async {
    final group = _group(40, selected: '🇸🇬 节点 39');
    final ctrl = await _pump(tester, group: group, scrollTo: '🇸🇬 节点 39');
    // 最后一个节点无法居中 → clamp 到 maxScrollExtent。
    expect(ctrl.offset, closeTo(ctrl.position.maxScrollExtent, 1.0),
        reason: '靠底节点 → 就近停在底部（maxScrollExtent）');
    expect(find.text('🇸🇬 节点 39'), findsOneWidget);
  });

  testWidgets('无 scrollToNode → 不滚动，停在顶部', (tester) async {
    final group = _group(40, selected: '🇸🇬 节点 20');
    final ctrl = await _pump(tester, group: group, scrollTo: '');
    expect(ctrl.offset, 0);
  });
}
