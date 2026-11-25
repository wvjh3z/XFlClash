import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;

import 'html_text.dart';

/// Rich HTML wins over guessing Markdown. Editors may also wrap Markdown
/// source in plain paragraphs and BRs. Never rewrite the stored notice.
String noticeRenderableHtml(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return '';
  var markdown = trimmed;
  // Ignore fenced/inline code when deciding whether the author supplied HTML.
  final outsideCode = trimmed.replaceAll(RegExp(r'(```|~~~)[\s\S]*?\1|`[^`\n]+`'), '');
  if (RegExp(r'<[a-zA-Z][\w-]*(?:\s[^>]*|/?)>').hasMatch(outsideCode)) {
    final body = htmlRenderableBody(trimmed);
    final fragment = html.parseFragment(body);
    final elements = fragment.querySelectorAll('*');
    if (elements.any((e) => !const {'p', 'div', 'br'}.contains(e.localName) || e.attributes.isNotEmpty)) return body;
    final text = StringBuffer();
    void flatten(dom.Node node) {
      if (node is dom.Text) {
        text.write(node.data);
      } else if (node is dom.Element && node.localName == 'br') {
        text.writeln();
      } else {
        for (final child in node.nodes) { flatten(child); }
        if (node is dom.Element) text.write('\n\n');
      }
    }
    flatten(fragment);
    markdown = text.toString().trim();
    if (!RegExp(r'[*_`#>\[\]~]|^\s*(?:[-+]|\d+[.)])\s', multiLine: true).hasMatch(markdown)) return body;
  }
  return md.markdownToHtml(markdown, extensionSet: md.ExtensionSet.commonMark);
}
