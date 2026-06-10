/// 自绘节点分组 [XbNodeGroup] 单测：类型标签 + 「自动」标记 + 只读组 + 类型说明 sheet。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/providers/state.dart'
    show selectedProxyNameProvider, proxyNameProvider, delayProvider;
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/xb_node_group.dart';

XbGroupSummary _group(
  XbGroupKind kind, {
  String name = '测试分组',
  List<String> nodeNames = const ['🇭🇰 香港 01', '🇯🇵 东京 02'],
}) {
  return XbGroupSummary(
    name: name,
    nodeCount: nodeNames.length,
    currentSelected: nodeNames.isNotEmpty ? nodeNames.first : '',
    isUrlTest: kind == XbGroupKind.urlTest,
    kind: kind,
    nodes: [
      for (final n in nodeNames) XbNodeItem(name: n, type: 'ss'),
    ],
  );
}

Future<void> pump(WidgetTester tester, XbGroupSummary group) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // 隔离 FlClash 内核 provider（避免触达真实 DB/profile）：选中态 + 延迟给固定值。
        selectedProxyNameProvider(group.name).overrideWithValue(
          group.nodes.isNotEmpty ? group.nodes.first.name : null,
        ),
        // selectedName 乐观分支：proxyNameProvider 给 null → 回退 selectedProxyNameProvider。
        proxyNameProvider(group.name).overrideWithValue(null),
        for (final n in group.nodes)
          delayProvider(proxyName: n.name, testUrl: null).overrideWithValue(38),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: XbNodeGroup(group: group),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('url-test：显示类型标签（含简短说明）+ 自动命中节点标「自动」+ 测延迟',
      (tester) async {
    await pump(tester, _group(XbGroupKind.urlTest));
    expect(find.textContaining('url-test'), findsOneWidget);
    expect(find.textContaining('自动选择低延迟节点'), findsOneWidget);
    // 计算选择组：core 命中节点（mock selected=首项）标「自动」。
    expect(find.text('自动'), findsOneWidget);
    // 可选组显示「测延迟」。
    expect(find.text('测延迟'), findsOneWidget);
  });

  testWidgets('url-test：自动命中第二个节点 → 「自动」标签跟随命中节点（不固定首项）',
      (tester) async {
    final group = _group(XbGroupKind.urlTest,
        nodeNames: const ['🇭🇰 香港 01', '🇯🇵 东京 02', '🇸🇬 新加坡 03']);
    // core 命中第二个节点（延迟最低），未手动锁定（proxyName=null → 自动模式）。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedProxyNameProvider(group.name)
              .overrideWithValue('🇯🇵 东京 02'),
          proxyNameProvider(group.name).overrideWithValue(null),
          for (final n in group.nodes)
            delayProvider(proxyName: n.name, testUrl: null)
                .overrideWithValue(38),
        ],
        child: MaterialApp(home: Scaffold(body: XbNodeGroup(group: group))),
      ),
    );
    await tester.pump();
    // 「自动」标签只出现一次，且在命中的第二个节点行（不在首项）。
    expect(find.text('自动'), findsOneWidget);
    final autoRow = find.ancestor(
      of: find.text('自动'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: autoRow.first, matching: find.text('🇯🇵 东京 02')),
      findsOneWidget,
      reason: '「自动」标签应与命中节点(东京 02)同行，而非固定第一项',
    );
  });

  testWidgets('url-test：手动锁定后 → 不显示「自动」标签（只选中勾）', (tester) async {
    final group = _group(XbGroupKind.urlTest);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedProxyNameProvider(group.name)
              .overrideWithValue(group.nodes.first.name),
          // 手动锁定首项（proxyName 非空 → 非自动模式）。
          proxyNameProvider(group.name)
              .overrideWithValue(group.nodes.first.name),
          for (final n in group.nodes)
            delayProvider(proxyName: n.name, testUrl: null)
                .overrideWithValue(38),
        ],
        child: MaterialApp(home: Scaffold(body: XbNodeGroup(group: group))),
      ),
    );
    await tester.pump();
    expect(find.text('自动'), findsNothing, reason: '手动锁定后不显示自动标签');
  });

  testWidgets('selector：类型标签 + 无「自动」标记', (tester) async {
    await pump(tester, _group(XbGroupKind.selector));
    expect(find.textContaining('selector'), findsOneWidget);
    expect(find.textContaining('手动选择节点'), findsOneWidget);
    expect(find.text('自动'), findsNothing);
  });

  testWidgets('load-balance：只读组仍可测延迟（与能否手选无关）', (tester) async {
    await pump(tester, _group(XbGroupKind.loadBalance));
    expect(find.textContaining('load-balance'), findsOneWidget);
    // 所有分组都可测延迟（看节点健康度），即便只读组。
    expect(find.text('测延迟'), findsOneWidget);
  });

  testWidgets('点 url-test 标签 ? → 只弹该类型说明（不列其它类型）', (tester) async {
    await pump(tester, _group(XbGroupKind.urlTest));
    await tester.tap(find.byIcon(Icons.help_outline));
    await tester.pumpAndSettle();
    expect(find.text('线路分组类型说明'), findsOneWidget);
    // 只显示被点的 url-test，不列其它类型。
    expect(find.textContaining('自动测速'), findsOneWidget);
    expect(find.text('load-balance'), findsNothing);
    expect(find.text('relay'), findsNothing);
  });
}
