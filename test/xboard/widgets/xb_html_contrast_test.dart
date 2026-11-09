import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/widgets/xb_html_contrast.dart';

void main() {
  const white = Color(0xFFFFFFFF);
  const dark = Color(0xFF13161D);

  test('author colors match approved prototype; passing values stay exact', () {
    expect(xbReadableHtmlColor(const Color(0xFFD92E1A), white),
        const Color(0xFFD92E1A));
    expect(xbReadableHtmlColor(const Color(0xFFCE2C2C), white),
        const Color(0xFFCE2C2C));
    expect(xbReadableHtmlColor(const Color(0xFFE05252), dark),
        const Color(0xFFE05252));
    expect(xbReadableHtmlColor(const Color(0xFFE05252), white),
        const Color(0xFFDB3434));
    expect(xbReadableHtmlColor(const Color(0xFFD92E1A), dark),
        const Color(0xFFE74734));
    expect(xbReadableHtmlColor(const Color(0xFFCE2C2C), dark),
        const Color(0xFFDA5353));
  });

  test('checks alpha against background and is idempotent', () {
    const passingAlpha = Color(0xE6000000);
    expect(xbReadableHtmlColor(passingAlpha, white), passingAlpha);
    for (final bg in [white, dark, const Color(0xFF808080)]) {
      for (final fg in [
        const Color(0x22D92E1A),
        const Color(0x00000000),
        const Color(0xFF777777),
        const Color(0xFF00FF00),
      ]) {
        final result = xbReadableHtmlColor(fg, bg);
        expect(xbHtmlContrastRatio(result, bg), greaterThanOrEqualTo(4.5));
        expect(xbReadableHtmlColor(result, bg), result);
      }
    }
  });

  for (final bg in [white, dark]) {
    testWidgets('resolved CSS, nested backgrounds, links and fonts on $bg',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: bg,
          body: Html(
            data: '''<style>.author { color: #D92E1A; }</style>
<div class="author">Heading<span>Inherited</span></div>
<div style="background-color:#ffffff;color:#ffffff">WhiteBox
<span style="background-color:rgba(0,0,0,0.8);color:rgba(0,0,0,0.2)">Nested</span></div>
<p><a href="https://example.com/plan">Link</a></p>
<span class="xbemoji">Emoji</span>''',
            style: {
              'body': Style(color: bg == white ? Colors.black : Colors.white),
              '.xbemoji': Style(fontFamily: 'Twemoji'),
            },
            extensions: [
              XbHtmlContrastExtension(background: bg, foreground: Colors.black),
            ],
            onLinkTap: (_, _, _) => tapped = true,
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final spans = <String, TextStyle>{};
      void collect(InlineSpan span, TextStyle inherited) {
        if (span is! TextSpan) return;
        final style = inherited.merge(span.style);
        if (span.text != null && span.text!.trim().isNotEmpty) {
          spans[span.text!.trim()] = style;
        }
        for (final child in span.children ?? <InlineSpan>[]) {
          collect(child, style);
        }
      }
      for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
        collect(widget.text, const TextStyle());
      }
      final expected = bg == white
          ? const Color(0xFFD92E1A)
          : const Color(0xFFE74734);
      expect(spans['Heading']!.color, expected);
      expect(spans['Inherited']!.color, expected);
      expect(xbHtmlContrastRatio(spans['WhiteBox']!.color!, white),
          greaterThanOrEqualTo(4.5));
      final nested = spans['Nested']!;
      expect(nested.backgroundColor, isNotNull);
      expect(xbHtmlContrastRatio(nested.color!, nested.backgroundColor!),
          greaterThanOrEqualTo(4.5));
      expect(spans['Emoji']!.fontFamily, 'Twemoji');
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('Link', findRichText: true),
      );
      final box = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
      ).first.toRect();
      await tester.tapAt(paragraph.localToGlobal(box.center));
      expect(tapped, isTrue);
    });
  }
}
