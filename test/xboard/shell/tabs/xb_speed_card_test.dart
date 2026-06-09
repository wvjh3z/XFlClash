/// W3.2 — XbSpeedCard 单测（Mbps 换算 / 上传不标绿 / 延迟 --）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/common/common.dart' show FixedList;
import 'package:fl_clash/models/models.dart' show Traffic;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_speed_card.dart';

Future<void> pumpCard(
  WidgetTester tester, {
  required num up,
  required num down,
  int? latencyMs,
}) async {
  final container = ProviderContainer(
    overrides: [
      trafficsProvider.overrideWithBuild(
        (ref, _) => FixedList<Traffic>(10, list: [Traffic(up: up, down: down)]),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: XbSpeedCard(latencyMs: latencyMs)),
      ),
    ),
  );
}

void main() {
  // 新布局：每张卡 = 图标 + RichText(数值 + 内联单位)，无独立标签行。
  // findRichText:true → 在 RichText 内匹配拼接文本（如「8.0 Mbps」「38 ms」）。
  testWidgets('字节/秒 → Mbps（×8/1e6，1 位小数）', (tester) async {
    // 1,000,000 B/s = 8 Mbps；500,000 B/s = 4 Mbps。
    await pumpCard(tester, down: 1000000, up: 500000);
    expect(find.textContaining('8.0', findRichText: true), findsOneWidget);
    expect(find.textContaining('4.0', findRichText: true), findsOneWidget);
    // 单位内联到数值后（RichText 拼接为「8.0 Mbps」）。
    expect(find.textContaining('Mbps', findRichText: true), findsNWidgets(2));
  });

  testWidgets('未传延迟 → 显示 --', (tester) async {
    await pumpCard(tester, down: 0, up: 0);
    // 未连接：延迟「--」、下载/上传「0 Kbps」。
    expect(find.textContaining('--', findRichText: true), findsOneWidget);
    expect(find.textContaining('Kbps', findRichText: true), findsNWidgets(2));
  });

  testWidgets('传延迟 → 显示数值 + ms 单位', (tester) async {
    await pumpCard(tester, down: 0, up: 0, latencyMs: 38);
    expect(find.textContaining('38', findRichText: true), findsOneWidget);
    expect(find.textContaining('ms', findRichText: true), findsOneWidget);
  });

  testWidgets('上传数字不标绿 + 等宽数字（R2.7/R8.4）', (tester) async {
    await pumpCard(tester, down: 1000000, up: 500000);
    final finder = find.textContaining('4.0', findRichText: true);
    final upText = tester.widget<RichText>(finder);
    final ctx = tester.element(finder);
    final scheme = Theme.of(ctx).colorScheme;
    final root = upText.text as TextSpan;
    // 数值主 span：同 onSurface（非绿）+ tabularFigures。
    expect(root.style?.color, scheme.onSurface);
    expect(
      root.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });
}
