import 'package:fl_clash/xboard/pages/legal_pages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('隐私页重点独立加粗，披露可读并可滚到提示（$brightness）', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const PrivacyPage(),
      ));
      final bold = <String>[];
      void visit(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.text != null && span.style?.fontWeight == FontWeight.w700) {
          bold.add(span.text!);
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child);
        }
      }
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        if (text.textSpan != null) visit(text.textSpan!);
      }
      expect(bold, containsAll(['不记录', '新加坡', 'Sentry', '支付服务商']));
      expect(find.textContaining('保留原始错误内容'), findsWidgets);
      expect(find.textContaining('完全退出并重新打开应用'), findsWidgets);
      final tip = find.textContaining('除法律强制要求外');
      await tester.ensureVisible(tip);
      expect(tip.hitTestable(), findsOneWidget);
      expect(tester.getSize(find.byIcon(Icons.shield_outlined)), const Size.square(18));
      expect(tester.takeException(), isNull);
    });
  }
}
