/// 测速中节点集合 + 节点页延迟行屏蔽中间跳变（显示转圈）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/providers/state.dart'
    show delayProvider, selectedProxyNameProvider, proxyNameProvider;
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/xb_node_group.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbSpinner;

Future<ProviderContainer> pumpNode(WidgetTester tester, int? rawDelay) async {
  final container = ProviderContainer(overrides: [
    delayProvider(proxyName: 'HK01', testUrl: null).overrideWithValue(rawDelay),
    selectedProxyNameProvider('HK').overrideWithValue(''),
    proxyNameProvider('HK').overrideWithValue(null),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
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
    ),
  ));
  await tester.pump();
  return container;
}

void main() {
  group('XbMeasuringNodesNotifier', () {
    test('同名节点的两轮测速分别结束，不提前解除测速态', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(xbMeasuringNodesProvider.notifier);
      n.start('HK01');
      n.start('HK01');
      n.finish('HK01');
      expect(c.read(xbMeasuringNodesProvider), {'HK01'});
      n.finish('HK01');
      expect(c.read(xbMeasuringNodesProvider), isEmpty);
      n.finish('HK01');
      expect(c.read(xbMeasuringNodesProvider), isEmpty);
    });

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
      final container = await pumpNode(t, 120);
      // 未测速中 → 显示延迟值。
      expect(find.text('60 ms'), findsOneWidget);
      expect(container.read(delayProvider(proxyName: 'HK01', testUrl: null)), 120);
      // 标记测速中 → 显示转圈，不再显示数字。
      container.read(xbMeasuringNodesProvider.notifier).start('HK01');
      await t.pump();
      expect(find.text('60 ms'), findsNothing);
      expect(find.byType(XbSpinner), findsWidgets);
      // 结束 → 恢复显示数字。
      container.read(xbMeasuringNodesProvider.notifier).finish('HK01');
      await t.pump();
      expect(find.text('60 ms'), findsOneWidget);
      expect(container.read(delayProvider(proxyName: 'HK01', testUrl: null)), 120);
    });
  });

  group('节点页延迟展示与原始状态', () {
    for (final raw in [1, 121]) {
      testWidgets('奇数原始延迟 $raw 向下取整，测速状态不变', (t) async {
        final container = await pumpNode(t, raw);
        final text = raw == 1 ? '0 ms' : '60 ms';
        expect(find.text(text), findsOneWidget);
        expect(find.text(raw == 1 ? '0.5 ms' : '60.5 ms'), findsNothing);
        expect(find.byType(XbSpinner), findsNothing);
        expect(container.read(delayProvider(proxyName: 'HK01', testUrl: null)), raw);
      });
    }

    testWidgets('显示值低于颜色阈值仍按原始延迟着色', (t) async {
      final container = await pumpNode(t, 700);
      final text = t.widget<Text>(find.text('350 ms'));
      expect(text.style!.color, const Color(0xFFC57F0A));
      expect(container.read(delayProvider(proxyName: 'HK01', testUrl: null)), 700);
    });

    testWidgets('原始零值继续表示测速中', (t) async {
      await pumpNode(t, 0);
      expect(find.byType(XbSpinner), findsOneWidget);
      expect(find.text('0 ms'), findsNothing);
    });

    testWidgets('原始负值继续表示超时', (t) async {
      await pumpNode(t, -1);
      expect(find.text('超时'), findsOneWidget);
      expect(find.byType(XbSpinner), findsNothing);
    });

    testWidgets('未知值继续显示单节点测速按钮', (t) async {
      await pumpNode(t, null);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Icon && widget.icon == Icons.bolt && widget.size == 18,
        ),
        findsOneWidget,
      );
      expect(find.text('超时'), findsNothing);
      expect(find.byType(XbSpinner), findsNothing);
    });
  });
}
