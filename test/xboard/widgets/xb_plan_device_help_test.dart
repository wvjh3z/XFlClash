import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/widgets/xb_plan_details.dart';
import 'package:fl_clash/xboard/widgets/xb_plan_device_help.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:material_ui/material_ui.dart';

void main() {
  test('only decorate the device field, including section and br layouts', () {
    const unrelated = '<p>备注：请保管好设备</p>';
    expect(withPlanDeviceHelp(unrelated), unrelated);
    for (final html in [
      '<p>💻 <b>设备</b> 个人 5 台设备同时使用</p>',
      '<div>📱 设备</div><div>个人 <b>5 台</b>设备同时使用</div>',
      '<div>💻 设备：个人 5 台设备同时使用<br>重置：每月</div>',
    ]) {
      expect(withPlanDeviceHelp(html), contains('设备同时使用<$deviceHelpTag>'));
    }
  });
  testWidgets('inline question stays on the text center and does not add space above the device row', (t) async {
    Future<void> show(String label) async {
      await t.pumpWidget(ProviderScope(child: MaterialApp(home: Scaffold(body: XbPlanDetails(
        compact: true, plan: PlanItem(id: 1, name: '示例', transferEnableGb: 0, prices: const [],
          description: '<p>节点　全节点可用</p><p>$label　个人 5 台设备同时使用</p><p>重置　每月重置可用流量</p>'),
      )))));
      await t.pumpAndSettle();
    }
    double middle(String value) {
      final finder = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains(value));
      final p = t.renderObject<RenderParagraph>(finder.last);
      final start = p.text.toPlainText().indexOf(value);
      final box = p.getBoxesForSelection(TextSelection(baseOffset:start,extentOffset:start+value.length)).first;
      return p.localToGlobal(box.toRect().center).dy;
    }
    await show('终端');
    final gap = middle('个人 5 台') - middle('全节点可用');
    await show('设备');
    expect(middle('个人 5 台') - middle('全节点可用'), closeTo(gap, 1));
    expect(t.getCenter(find.byIcon(Icons.help_outline_rounded)).dy, closeTo(middle('个人 5 台'), 2));
  });
  testWidgets(
    'tap inline help, scroll on a narrow screen and dismiss without leaving plan',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(320, 600);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: XbPlanDetails(
                plan: const PlanItem(
                  id: 1,
                  name: '示例',
                  description: '<p>💻 <b>设备</b> 个人 5 台设备同时使用</p>',
                  transferEnableGb: 0,
                  prices: [],
                ),
              ),
            ),
          ),
        ),
      );
      final help = find.byTooltip('查看设备使用与共享说明');
      expect(help, findsOneWidget);
      await t.tap(help);
      await t.pumpAndSettle();
      expect(find.text('设备使用与共享说明'), findsOneWidget);
      expect(find.text('支持'), findsNWidgets(2));
      expect(find.text('严禁'), findsOneWidget);
      final badges = [find.text('支持').first, find.text('支持').last, find.text('严禁')];
      final fills = <Color?>[];
      final rights = <double>[];
      for (final badge in badges) {
        final container = find.ancestor(of: badge, matching: find.byType(Container)).first;
        final widget = t.widget<Container>(container);
        expect(widget.padding, const EdgeInsets.symmetric(horizontal: 7, vertical: 2));
        final decoration = widget.decoration! as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(8));
        fills.add(decoration.color);
        rights.add(t.getRect(container).right);
      }
      expect(fills.first, isNotNull);
      expect(fills[1], fills.first);
      expect(fills.last, isNot(fills.first));
      expect(rights, everyElement(closeTo(rights.first, .5)));
      expect(find.text('支持个人名下手机、电脑、平板等终端合理使用。'), findsOneWidget);
    expect(find.text('支持同住家庭成员或小范围同一 Wi-Fi 环境下日常使用。'), findsOneWidget);
    expect(find.text('严禁在社交网络、论坛公开订阅链接或节点，严禁分享给他人使用或转租给他人。'), findsOneWidget);
    expect(find.text('请保护好订阅链接，个人及家庭日常共享请勿公开传播。'), findsOneWidget);
    await t.tap(find.text('我知道了'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(help, findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
