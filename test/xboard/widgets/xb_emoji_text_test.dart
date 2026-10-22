import 'package:fl_clash/xboard/widgets/xb_emoji_text.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(
  Widget child, {
  TextDirection direction = TextDirection.ltr,
  double scale = 1,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Directionality(
      textDirection: direction,
      child: Center(child: SizedBox(width: 240, child: child)),
    ),
  ),
);

RenderParagraph paragraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(XbEmojiText),
        matching: find.byType(RichText),
      ),
    );

void main() {
  testWidgets(
    'explicit newlines and mixed-direction text keep their content and line layout',
    (tester) async {
      const value = 'Plan 123\nمرحبا 🇭🇰';
      await tester.pumpWidget(
        host(
          const XbEmojiText(
            value,
            style: TextStyle(fontSize: 14),
            textAlign: TextAlign.right,
            maxLines: 2,
          ),
        ),
      );
      final p = paragraph(tester);
      expect(p.text.toPlainText(), value);
      expect(p.didExceedMaxLines, isFalse);
      final boxes = p.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: value.length),
      );
      expect(boxes.map((box) => box.top).toSet(), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('center and right alignment move actual glyph boxes', (
    tester,
  ) async {
    final lefts = <double>[];
    for (final align in [TextAlign.left, TextAlign.center, TextAlign.right]) {
      await tester.pumpWidget(
        host(
          XbEmojiText(
            'ABC 123',
            style: const TextStyle(fontSize: 14),
            textAlign: align,
          ),
        ),
      );
      final boxes = paragraph(tester).getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 7),
      );
      expect(boxes, isNotEmpty);
      lefts.add(boxes.first.left);
      expect(tester.takeException(), isNull);
    }
    expect(lefts[0], lessThan(lefts[1]));
    expect(lefts[1], lessThan(lefts[2]));
  });

  testWidgets(
    'only emoji spans use Twemoji; ordinary digits keep the text font',
    (tester) async {
      const value = '套餐 123 🇭🇰 45.6 🚀';
      await tester.pumpWidget(
        host(
          const XbEmojiText(
            value,
            style: TextStyle(fontSize: 14, fontFamily: 'Roboto'),
          ),
        ),
      );
      final text = paragraph(tester).text as TextSpan;
      expect(text.toPlainText(), value);
      final spans = text.children!.cast<TextSpan>().toList();
      expect(
        spans.where((s) => s.style?.fontFamily == 'Twemoji').map((s) => s.text),
        ['🇭🇰', '🚀'],
      );
      expect(
        spans
            .where((s) => s.text!.contains('123') || s.text!.contains('45.6'))
            .every((s) => s.style?.fontFamily == 'Roboto'),
        isTrue,
      );
    },
  );

  testWidgets(
    'long account or plan text remains one line with ellipsis at large scale',
    (tester) async {
      await tester.pumpWidget(
        host(
          const XbEmojiText(
            'Long plan name 1234567890 Long plan name 1234567890',
            style: TextStyle(fontSize: 16),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          scale: 1.4,
        ),
      );
      expect(paragraph(tester).didExceedMaxLines, isTrue);
      expect(paragraph(tester).textScaler.scale(10), 14);
      expect(paragraph(tester).size.width, 240);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('start follows RTL and empty text is safe', (tester) async {
    await tester.pumpWidget(
      host(
        const XbEmojiText('123', style: TextStyle(fontSize: 14)),
        direction: TextDirection.rtl,
      ),
    );
    expect(paragraph(tester).textAlign, TextAlign.start);
    final boxes = paragraph(
      tester,
    ).getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 3));
    expect(boxes.first.left, greaterThan(0));
    await tester.pumpWidget(host(const XbEmojiText('')));
    expect(paragraph(tester).text.toPlainText(), '');
    expect(tester.takeException(), isNull);
  });
}
