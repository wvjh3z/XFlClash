/// 「3 次取最低测速中」节点集合 + 节点页延迟行屏蔽中间跳变（显示转圈）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/providers/state.dart'
    show delayProvider, selectedProxyNameProvider, proxyNameProvider;
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/xb_node_group.dart';

void main() {
  group('XbMeasuringNodesNotifier', () {
    test('start / finish 增删节点', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(xbMeasuringNodesProvider.notifier);
      expect(c.read(xbMeasuringNodesProvider), isEmpty);
      n.start('HK01');
      expect(c.read(xbMeasuringNodesProvider), {'HK01'});
      n.start('JP01');
      expect(c.read(xbMeasuringNodesProvider), {'HK01', 'JP01'});
      n.finish('HK01');
      expect(c.read(xbMeasuringNodesProvider), {'JP01'});
    });
  });

  group('节点页延迟行：测速中屏蔽跳变', () {
    testWidgets('节点在测速集合中 → 显示转圈（即便有延迟值）', (t) async {
      late ProviderContainer container;
      await t.pumpWidget(ProviderScope(
        overrides: [
          delayProvider(proxyName: 'HK01', testUrl: null)
              .overrideWithValue(120), // 有值
          selectedProxyNameProvider('HK').overrideWithValue(''),
          proxyNameProvider('HK').overrideWithValue(null),
        ],
        child: Consumer(builder: (ctx, ref, _) {
          container = ProviderScope.containerOf(ctx);
          return const MaterialApp(
            home: Scaffold(
              body: XbNodeGroup(
                group: XbGroupSummary(
                  name: 'HK',
                  nodeCount: 1,
                  currentSelected: '',
                  isUrlTest: false,
                  kind: XbGroupKind.selector,
                  nodes: [XbNodeItem(name: 'HK01', type: 'ss')],
                ),
              ),
            ),
          );
        }),
      ));
      await t.pump();
      // 未测速中 → 显示延迟值。
      expect(find.text('120 ms'), findsOneWidget);
      // 标记测速中 → 显示转圈，不再显示数字。
      container.read(xbMeasuringNodesProvider.notifier).start('HK01');
      await t.pump();
      expect(find.text('120 ms'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      // 结束 → 恢复显示数字。
      container.read(xbMeasuringNodesProvider.notifier).finish('HK01');
      await t.pump();
      expect(find.text('120 ms'), findsOneWidget);
    });
  });
}
