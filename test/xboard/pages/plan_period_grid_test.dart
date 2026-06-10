/// 计费周期卡网格尺寸契约：注入 6 周期套餐，量出每张周期卡真实尺寸，
/// 断言**所有卡等宽等高**（杜绝"变形/大小不一"）。客观尺寸断言，不靠肉眼。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbSelectableOption;

PlanItem _plan6() => const PlanItem(
      id: 1,
      name: '标准套餐',
      transferEnableGb: 250,
      prices: [
        PricePlan(period: XbPlanPeriod.monthly, amountYuan: 25),
        PricePlan(period: XbPlanPeriod.quarterly, amountYuan: 73.5),
        PricePlan(period: XbPlanPeriod.halfYearly, amountYuan: 142.5),
        PricePlan(period: XbPlanPeriod.yearly, amountYuan: 270),
        PricePlan(period: XbPlanPeriod.twoYearly, amountYuan: 480),
        PricePlan(period: XbPlanPeriod.threeYearly, amountYuan: 630),
      ],
    );

Future<void> _pump(WidgetTester tester, {double textScale = 1.0}) async {
  tester.view.physicalSize = const Size(393, 852); // 典型手机宽
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: PlanDetailPage(plan: _plan6()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('6 周期卡：全部等宽等高（默认字号）', (tester) async {
    await _pump(tester);
    final cards = find.byType(XbSelectableOption);
    expect(cards, findsNWidgets(6));

    final sizes = <Size>[
      for (var i = 0; i < 6; i++) tester.getSize(cards.at(i)),
    ];
    final first = sizes.first;
    for (var i = 1; i < sizes.length; i++) {
      expect(sizes[i].width, closeTo(first.width, 0.5),
          reason: '第 $i 张卡宽度与第 0 张不一致：${sizes[i]} vs $first');
      expect(sizes[i].height, closeTo(first.height, 0.5),
          reason: '第 $i 张卡高度与第 0 张不一致：${sizes[i]} vs $first');
    }
  });

  testWidgets('同一行左右两卡顶端对齐（dy 相同）', (tester) async {
    await _pump(tester);
    final cards = find.byType(XbSelectableOption);
    // 行 0：第 0、1 张；行 1：第 2、3 张；行 2：第 4、5 张。
    for (final pair in [
      [0, 1],
      [2, 3],
      [4, 5]
    ]) {
      final a = tester.getTopLeft(cards.at(pair[0]));
      final b = tester.getTopLeft(cards.at(pair[1]));
      expect(b.dy, closeTo(a.dy, 0.5),
          reason: '行内卡片 ${pair[0]}/${pair[1]} 顶端未对齐：${a.dy} vs ${b.dy}');
    }
  });

  testWidgets('大字号 1.5 下仍等高（不溢出不变形）', (tester) async {
    await _pump(tester, textScale: 1.5);
    expect(tester.takeException(), isNull);
    final cards = find.byType(XbSelectableOption);
    final sizes = <Size>[
      for (var i = 0; i < 6; i++) tester.getSize(cards.at(i)),
    ];
    for (var i = 1; i < sizes.length; i++) {
      expect(sizes[i].height, closeTo(sizes.first.height, 0.5),
          reason: '大字号下第 $i 张卡高度不一致');
    }
  });
}
