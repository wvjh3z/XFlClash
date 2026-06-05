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
  testWidgets('字节/秒 → Mbps（×8/1e6，1 位小数）', (tester) async {
    // 1,000,000 B/s = 8 Mbps；500,000 B/s = 4 Mbps。
    await pumpCard(tester, down: 1000000, up: 500000);
    expect(find.text('8.0'), findsOneWidget);
    expect(find.text('4.0'), findsOneWidget);
    expect(find.text('下载 Mbps'), findsOneWidget);
    expect(find.text('上传 Mbps'), findsOneWidget);
  });

  testWidgets('未传延迟 → 显示 --', (tester) async {
    await pumpCard(tester, down: 0, up: 0);
    expect(find.text('--'), findsOneWidget);
    expect(find.text('延迟 ms'), findsOneWidget);
  });

  testWidgets('传延迟 → 显示数值', (tester) async {
    await pumpCard(tester, down: 0, up: 0, latencyMs: 38);
    expect(find.text('38'), findsOneWidget);
  });

  testWidgets('上传数字不标绿 + 等宽数字（R2.7/R8.4）', (tester) async {
    await pumpCard(tester, down: 1000000, up: 500000);
    final ctx = tester.element(find.text('4.0'));
    final scheme = Theme.of(ctx).colorScheme;
    final upText = tester.widget<Text>(find.text('4.0'));
    // 上传同 onSurface（非绿），且含 tabularFigures。
    expect(upText.style?.color, scheme.onSurface);
    expect(
      upText.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });
}
