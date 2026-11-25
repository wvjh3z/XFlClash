import 'package:fl_clash/xboard/util/notice_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

void main() {
  test('Markdown headings, emphasis, lists, quote, code and relative link', () {
    final doc = html.parseFragment(noticeRenderableHtml(
      '## 维护公告\n\n**重要**\n\n- 第一项\n- 第二项\n\n> 请注意\n\n'
      '`命令`\n\n[查看说明](/help)\n\n```html\n<b>示例</b>\n```',
    ));
    expect(doc.querySelector('h2')!.text, '维护公告');
    expect(doc.querySelector('strong')!.text, '重要');
    expect(doc.querySelectorAll('li'), hasLength(2));
    expect(doc.querySelector('blockquote')!.text.trim(), '请注意');
    expect(doc.querySelector('code')!.text, '命令');
    expect(doc.querySelector('a')!.attributes['href'], '/help');
    expect(doc.querySelector('pre code')!.text.trim(), '<b>示例</b>');
  });
  test('plain editor wrappers preserve ordinary HTML and support Markdown', () {
    final doc = html.parseFragment(noticeRenderableHtml('<p>## 公告</p><p>**重要**</p><div>- 甲<br>- 乙</div>'));
    expect(doc.querySelector('h2')!.text, '公告');
    expect(doc.querySelector('strong')!.text, '重要');
    expect(doc.querySelectorAll('li'), hasLength(2));
    const plain = '<p>第一行<br>第二行</p>';
    expect(noticeRenderableHtml(plain), plain);
  });
  test('fenced examples retain literal script and template text', () {
    final doc = html.parseFragment(noticeRenderableHtml('```html\n<script>demo()</script>{{example}}\n```'));
    expect(doc.querySelector('code')!.text.trim(), '<script>demo()</script>{{example}}');
    expect(doc.querySelector('script'), isNull);
  });
  test('rich HTML keeps links, styles and literal Markdown in code', () {
    const rich = '<div style="background:#fff;color:#123"><strong>公告</strong>'
        '<a href="/help">查看</a><code>**literal**</code></div>';
    expect(noticeRenderableHtml(rich), rich);
  });
}
