import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/widgets/xb_plan_details.dart';
import 'package:fl_clash/xboard/widgets/xb_plan_device_help.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
