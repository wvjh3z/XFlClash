import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/confirmed_order.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

const _trade = '2026112400000000000000000000000000000000000000000000000000008946';

class _Control extends Mock implements XboardService, XboardConfirmedOrderControl {
  _Control({this.sameSelection = false, this.balance = 600, this.surplus = 0});
  final bool sameSelection;
  final int balance;
  final int? surplus;
  bool? accepted;
  int replacements = 0;

  @override
  Future<XbResult<String?>> confirmOrder(ConfirmedOrderQuote quote, {
    required bool Function() isActive,
    required Future<bool> Function(ConfirmedOrderConflict) confirm,
  }) async {
    accepted = await confirm(ConfirmedOrderConflict(
      quote: quote,
      sameSelection: sameSelection,
      existingTradeNo: _trade,
      existingPlanName: '标准套餐',
      existingPeriod: XbPlanPeriod.monthly,
      existingPayableCents: 1900,
      existingBalanceCents: balance,
      existingAppliedSurplusCents: surplus,
    ));
    if (accepted == true && isActive()) replacements++;
    return const XbSuccess(null);
  }
}

Future<void> _open(WidgetTester tester, _Control control, {
  Size size = const Size(390, 844), double scale = 1, bool Function()? active,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale)), child: child!),
    home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => submitConfirmedOrder(
        context: context, service: control, isActive: active ?? () => true,
        quote: ConfirmedOrderQuote(planId: control.sameSelection ? 1 : 2,
          planName: control.sameSelection ? '标准套餐' : '轻量套餐',
          period: control.sameSelection ? XbPlanPeriod.monthly : XbPlanPeriod.yearly,
          estimatedCents: control.sameSelection ? 2500 : 16200,
          catalogCents: control.sameSelection ? 2500 : 16200),
      ),
      child: const Text('结算'),
    ))),
  ));
  await tester.tap(find.text('结算'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('零抵扣不展示订单明细入口', (t) async {
    await _open(t, _Control(balance: 0, surplus: 0));
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text('查看订单明细'), findsNothing);
    expect(find.textContaining('已抵扣'), findsNothing);
  });
  testWidgets('更换：右列实际字形右齐且周期金额同一行，明细不挤占默认布局', (tester) async {
    final control = _Control();
    await _open(tester, control);
    final rightEdges = <double>[];
    for (final value in ['标准套餐', '月付 · ¥19.00', '轻量套餐', '年付 · ¥162.00']) {
      final text = tester.renderObject<RenderParagraph>(find.text(value));
      final boxes = text.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: value.length));
      expect(boxes, isNotEmpty);
      expect(boxes.map((b) => b.top).toSet(), hasLength(1), reason: value);
      final right = boxes.map((b) => b.right).reduce((a, b) => a > b ? a : b);
      rightEdges.add(text.localToGlobal(Offset(right, 0)).dx);
    }
    for (final edge in rightEdges) {
      expect(edge, closeTo(rightEdges.first, 1));
    }
    expect(tester.widget<Text>(find.text('本次选择与原订单不同')).textAlign, TextAlign.start);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.textContaining('已抵扣'), findsNothing);
    final cancel = find.widgetWithText(OutlinedButton, '再想想');
    final confirm = find.widgetWithText(FilledButton, '取消旧单并下单');
    expect(tester.getSize(confirm), tester.getSize(cancel));
    expect(tester.getSize(confirm).height, 44);
    expect(find.text('查看订单明细'), findsNothing);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(control.accepted, isFalse);
    expect(control.replacements, 0);
  });

  testWidgets('320dp / 1.4 不展示明细，保留取消和 owner 守卫', (tester) async {
    var active = true;
    final control = _Control(surplus: null);
    await _open(tester, control, size: const Size(320, 440), scale: 1.4, active: () => active);
    expect(find.text('查看订单明细'), findsNothing);
    expect(find.text('再想想').hitTestable(), findsOneWidget);
    active = false;
    await tester.tap(find.text('取消旧单并下单'));
    await tester.pumpAndSettle();
    expect(control.accepted, isFalse);
    expect(control.replacements, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同套餐异价也只能确认替换订单', (tester) async {
    final control = _Control(sameSelection: true, balance: 0, surplus: 300);
    await _open(tester, control);
    expect(find.text('月付 · ¥25.00'), findsOneWidget);
    expect(find.text('继续支付旧单'), findsNothing);
    expect(find.text('查看订单明细'), findsNothing);
    expect(find.text('已有待支付订单'), findsOneWidget);
    expect(find.text('月付 · ¥19.00'), findsOneWidget);
    await tester.tap(find.text('取消旧单并下单'));
    await tester.pumpAndSettle();
    expect(control.accepted, isTrue);
    expect(control.replacements, 1);
  });
}
