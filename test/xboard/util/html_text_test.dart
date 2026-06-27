/// htmlToPlainText — 套餐描述 HTML → 纯文本（保留换行/列表语义）。

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/util/html_text.dart';

void main() {
  group('htmlToPlainText', () {
    test('<br> → 换行', () {
      expect(htmlToPlainText('第一行<br>第二行'), '第一行\n第二行');
      expect(htmlToPlainText('a<br/>b<BR />c'), 'a\nb\nc');
    });

    test('<p> 段落 → 换行分隔', () {
      expect(htmlToPlainText('<p>段一</p><p>段二</p>'), '段一\n段二');
    });

    test('<ul><li> → 项目符号', () {
      final out = htmlToPlainText('<ul><li>不限速</li><li>多设备</li></ul>');
      expect(out, contains('• 不限速'));
      expect(out, contains('• 多设备'));
    });

    test('剥除 <strong> 等内联标签保留文本', () {
      expect(htmlToPlainText('<strong>高级</strong>套餐'), '高级套餐');
    });

    test('HTML 实体解码', () {
      expect(htmlToPlainText('A&amp;B&nbsp;C'), 'A&B C');
      expect(htmlToPlainText('&lt;tag&gt;'), '<tag>');
      expect(htmlToPlainText('&#65;&#x42;'), 'AB');
    });

    test('折叠多余空行', () {
      expect(htmlToPlainText('a<br><br><br><br>b'), 'a\n\nb');
    });

    test('纯文本原样返回（trim）', () {
      expect(htmlToPlainText('  普通套餐描述  '), '普通套餐描述');
    });

    test('空串 → 空串', () {
      expect(htmlToPlainText(''), '');
    });

    test('真实 Xboard 富文本样例', () {
      const html = '<p>套餐包含：</p><ul><li>不限速</li><li>全球节点</li></ul>'
          '<p>有效期 30 天</p>';
      final out = htmlToPlainText(html);
      expect(out, contains('套餐包含：'));
      expect(out, contains('• 不限速'));
      expect(out, contains('• 全球节点'));
      expect(out, contains('有效期 30 天'));
      expect(out, isNot(contains('<')));
    });
  });

  group('looksLikeHtml', () {
    test('含标签 → true', () {
      expect(looksLikeHtml('<p>x</p>'), isTrue);
    });
    test('含实体 → true', () {
      expect(looksLikeHtml('a&amp;b'), isTrue);
    });
    test('纯文本 → false', () {
      expect(looksLikeHtml('普通文本'), isFalse);
    });
  });

  group('wrapEmojiForHtml（只包 emoji，不动数字/标签）', () {
    test('emoji 被包进 .xbemoji span', () {
      expect(wrapEmojiForHtml('a📦b'),
          'a<span class="$kXbEmojiClass">📦</span>b');
    });

    test('数字不被包（防 Twemoji 吃数字的核心）', () {
      final out = wrapEmojiForHtml('<div>每月 <b>100GB</b> 📦 <b>12CNY</b></div>');
      // emoji 被包
      expect(out, contains('<span class="$kXbEmojiClass">📦</span>'));
      // 数字所在 <b> 原样保留，未被 xbemoji 包裹
      expect(out, contains('<b>100GB</b>'));
      expect(out, contains('<b>12CNY</b>'));
      // 数字串不应出现在 xbemoji span 内
      expect(out, isNot(contains('xbemoji">100')));
      expect(out, isNot(contains('xbemoji">12')));
    });

    test('标签原样保留（属性不被当文本处理）', () {
      const html = '<div style="color:#D92E1A" class="hdr">x</div>';
      expect(wrapEmojiForHtml(html), html);
    });

    test('无 emoji → 原样', () {
      const html = '<b>100GB</b> · <b>300Mbps</b>';
      expect(wrapEmojiForHtml(html), html);
    });

    test('带变体选择符的 emoji（⚠️ / ✅）也被包', () {
      final out = wrapEmojiForHtml('<div>⚠️ 注意 ✅ 好</div>');
      // 至少出现两个 xbemoji span（⚠️ 与 ✅）
      expect(kXbEmojiClass, 'xbemoji');
      expect(RegExp('class="$kXbEmojiClass"').allMatches(out).length,
          greaterThanOrEqualTo(2));
    });

    test('空串 → 空串', () {
      expect(wrapEmojiForHtml(''), '');
    });
  });
}
