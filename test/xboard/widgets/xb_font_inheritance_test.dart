import 'package:fl_clash/xboard/widgets/xb_emoji_text.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _platforms = {
  TargetPlatform.android,
  TargetPlatform.windows,
  TargetPlatform.macOS,
  TargetPlatform.linux,
};

RenderParagraph _paragraph(WidgetTester tester, String text) => tester
    .renderObjectList<RenderParagraph>(find.byType(RichText))
    .singleWhere((p) => p.text.toPlainText() == text);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'brand theme retains platform typography in $brightness',
      (tester) async {
        // No font assets or RenderParagraph rewriting: compare actual Material
        // defaults on the target platform with the production brand theme.
        final defaults = ThemeData(brightness: brightness);
        final expectedFamily = defaults.textTheme.bodyMedium!.fontFamily;
        for (final brandName in ['OmoFly', '袋鼠加速']) {
          final theme = buildXbTheme(
            brandColor: const Color(0xffd92e1a),
            brightness: brightness,
          );
          final text = theme.textTheme;
          for (final style in [
            text.headlineSmall,
            text.titleLarge,
            text.titleMedium,
            text.titleSmall,
            text.bodyMedium,
            text.bodySmall,
            text.labelLarge,
            text.labelMedium,
          ]) {
            expect(style!.fontFamily, expectedFamily);
            expect(style.fontFamilyFallback, isNot(contains('Twemoji')));
          }
          await tester.pumpWidget(
            MaterialApp(
              theme: defaults,
              home: XbBrandTheme(
                brandColor: const Color(0xffd92e1a),
                child: Scaffold(
                  appBar: AppBar(title: Text(brandName)),
                  body: ListView(
                    children: [
                      const Text('首页 节点 我的 设置 123'),
                      const XbEmojiText('套餐 100 GB'),
                      FilledButton(onPressed: () {}, child: const Text('连接')),
                      OutlinedButton(onPressed: () {}, child: const Text('续费')),
                      TextButton(onPressed: () {}, child: const Text('教程')),
                      const ListTile(title: Text('用户信息')),
                      const TextField(controller: null),
                      const AlertDialog(
                        title: Text('确认订单'),
                        content: Text('价格 ¥12.50'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.enterText(find.byType(TextField), '邮箱 123@example.com');
          for (final label in [
            brandName,
            '首页 节点 我的 设置 123',
            '套餐 100 GB',
            '连接',
            '续费',
            '教程',
            '用户信息',
            '确认订单',
            '价格 ¥12.50',
          ]) {
            expect(
              _paragraph(tester, label).text.style!.fontFamily,
              expectedFamily,
              reason: label,
            );
          }
          final editable = tester.widget<EditableText>(
            find.byType(EditableText),
          );
          expect(editable.style.fontFamily, expectedFamily);
          expect(editable.controller.text, '邮箱 123@example.com');
          expect(_paragraph(tester, '连接').text.style!.color, Colors.white);
          expect(_paragraph(tester, '连接').text.style!.fontSize, 15.5);
          expect(_paragraph(tester, '教程').text.style!.fontSize, 14);
          expect(
            _paragraph(tester, '续费').text.style!.color,
            theme.colorScheme.primary,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      },
      variant: const TargetPlatformVariant(_platforms),
    );
  }

  testWidgets(
    'emoji inherits ambient family and fallback with omitted or partial style',
    (tester) async {
      const ambient = TextStyle(
        fontFamily: 'FixtureBody',
        fontFamilyFallback: ['FixtureCjk'],
        fontSize: 14,
        color: Colors.black,
      );
      for (final style in <TextStyle?>[
        null,
        const TextStyle(fontWeight: FontWeight.w700),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: DefaultTextStyle(
              style: ambient,
              child: XbEmojiText('套餐 123 🇭🇰 45.6 🚀', style: style),
            ),
          ),
        );
        final p = _paragraph(tester, '套餐 123 🇭🇰 45.6 🚀');
        final spans = (p.text as TextSpan).children!.cast<TextSpan>();
        for (final span in spans) {
          final emoji = span.text == '🇭🇰' || span.text == '🚀';
          expect(span.style!.fontFamily, emoji ? 'Twemoji' : 'FixtureBody');
          expect(span.style!.fontFamilyFallback, ['FixtureCjk']);
          expect(span.style!.fontWeight, style?.fontWeight);
        }
        expect(tester.takeException(), isNull);
      }
    },
  );
}
