/// XbFitText 行为契约测试（conventions §11 框架：单行完整展示、绝不省略号）。
///
/// 契约（含故障路径——超宽时必须缩放而非折行/截断）：
///   1. 够位：原字号、单行、完整文本、无省略号。
///   2. 超宽：完整文本仍在（无 …）、单行、且内部文本自然宽 > 容器宽（证明走 scaleDown 缩放，
///      不是折行也不是省略）。
///   3. .rich：多段样式拼成的完整文本可见、单行、无省略。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_components.dart';

Widget _host({required double width, required Widget child}) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: child)),
      ),
    );

RenderParagraph _para(WidgetTester t) => t.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(XbFitText),
        matching: find.byType(RichText),
      ),
    );

void main() {
  const longText =
      '每月 100GB 流量 · 峰值网速 300Mbps · 三网 IPEL 专线 · OMO 视频加速节点 · 限 5 台设备';

  testWidgets('够位：完整展示、单行、无省略号', (t) async {
    await t.pumpWidget(_host(
      width: 400,
      child: const XbFitText('每月 100GB · 300Mbps', style: TextStyle(fontSize: 12)),
    ));
    expect(find.byType(FittedBox), findsOneWidget);
    expect(find.text('每月 100GB · 300Mbps', findRichText: true), findsOneWidget);
    expect(find.textContaining('…', findRichText: true), findsNothing);
    expect(_para(t).size.height, lessThan(40)); // 单行
  });

  testWidgets('超宽：等比缩放而非折行/省略（内部自然宽 > 容器宽，文本完整）', (t) async {
    await t.pumpWidget(_host(
      width: 120,
      child: const XbFitText(longText, style: TextStyle(fontSize: 12)),
    ));
    // 完整文本仍在（没被省略号截断）。
    expect(find.text(longText, findRichText: true), findsOneWidget);
    expect(find.textContaining('…', findRichText: true), findsNothing);
    final p = _para(t);
    expect(p.size.height, lessThan(40), reason: '必须单行');
    expect(p.size.width, greaterThan(120),
        reason: '内部文本按自然宽单行排布（>容器），由 FittedBox 缩放 → 非折行非截断');
  });

  testWidgets('.rich：多段样式拼成完整文本、单行、无省略', (t) async {
    await t.pumpWidget(_host(
      width: 60,
      child: const XbFitText.rich(
        TextSpan(children: [
          TextSpan(text: '¥', style: TextStyle(fontSize: 14)),
          TextSpan(text: '142.50', style: TextStyle(fontSize: 28)),
        ]),
      ),
    ));
    expect(find.byType(FittedBox), findsOneWidget);
    expect(find.text('¥142.50', findRichText: true), findsOneWidget);
    expect(find.textContaining('…', findRichText: true), findsNothing);
  });
}
