/// HTML 文本工具：纯文本降级（`htmlToPlainText`）/ flutter_html 正文清洗（`htmlRenderableBody`）
/// / emoji 片段包裹（`wrapEmojiForHtml`，仅依赖 `emoji_regex`，不引入 flutter_html）。
///
/// Xboard 后端套餐 `content`/`description` 常是富文本编辑器存的 HTML（`<br>` / `<p>` /
/// `<ul><li>` / `<strong>` 等）。`htmlToPlainText` 转纯文本 + 保留换行/列表语义：
/// - `<br>` / `</p>` / `</li>` / `</div>` → 换行
/// - `<li>` → `• `（列表项前缀）
/// - 其余标签剥除
/// - HTML 实体解码（`&amp;` `&lt;` `&nbsp;` 等）
/// - 折叠多余空行（≥3 连续换行 → 2）
library;

import 'package:emoji_regex/emoji_regex.dart';

/// 把 HTML 片段转为带换行/列表语义的纯文本。非 HTML 输入原样 trim 返回。
String htmlToPlainText(String input) {
  if (input.isEmpty) return '';
  var s = input;

  // 1. 块级结束标签 / 换行标签 → 换行（先处理，避免被通用剥标签吞掉语义）。
  s = s.replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(
      RegExp(r'</\s*(p|div|li|tr|h[1-6])\s*>', caseSensitive: false), '\n');
  // 2. 列表项开始 → 项目符号。
  s = s.replaceAll(RegExp(r'<\s*li[^>]*>', caseSensitive: false), '• ');
  // 3. 剥除其余所有标签。
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  // 4. HTML 实体解码（常见集）。
  s = _decodeEntities(s);
  // 5. 行尾空白 + 折叠多余空行。
  s = s
      .split('\n')
      .map((line) => line.trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return s;
}

String _decodeEntities(String s) {
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  // 数字实体 &#123; / &#x1F600;
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code != null ? String.fromCharCode(code) : m.group(0)!;
  });
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return code != null ? String.fromCharCode(code) : m.group(0)!;
  });
  return out;
}

/// 是否含 HTML 标签（用于判断是否需要转换；纯文本可跳过）。
bool looksLikeHtml(String s) =>
    RegExp(r'<\s*[a-zA-Z/][^>]*>').hasMatch(s) || s.contains('&');

/// `wrapEmojiForHtml` 给 emoji 片段套的 class（flutter_html Style map 据此只给 emoji 套
/// Twemoji 字体）。
const String kXbEmojiClass = 'xbemoji';

/// 把 HTML 文本里的 emoji 片段包成 `<span class="xbemoji">…</span>`，供 flutter_html 渲染。
///
/// **为什么需要**（与 `EmojiText` 同源策略）：Twemoji 是彩色 emoji 字体，其 cmap **含 ASCII
/// 数字 0-9 / `#` / `*`**（keycap emoji 的基字）。若把 Twemoji 设为整段 body 的
/// `fontFamilyFallback`，flutter_html 会把普通数字也回退给 Twemoji 渲染成不可见的 COLR 基字
/// → **数字消失**（CJK / 拉丁字母不受影响，因 Twemoji 不含其字形）。
///
/// 故**不**用全局 fallback，而是只把真正的 emoji 包进 `.xbemoji` span，Style map 里
/// `'.xbemoji': Style(fontFamily: 'Twemoji')` 精确套字体；数字 / 正文走默认字体，正常显示。
///
/// **只处理标签之间的文本**（`onNonMatch`），不碰标签内部（属性里不会有 emoji，且避免破坏标签）。
String wrapEmojiForHtml(String html) {
  if (html.isEmpty) return html;
  final emoji = emojiRegex();
  // 按「标签 / 非标签文本」切分：标签原样保留，仅在文本段内包裹 emoji。
  return html.splitMapJoin(
    RegExp(r'<[^>]*>'),
    onMatch: (m) => m.group(0)!, // 标签：原样
    onNonMatch: (text) => text.isEmpty
        ? text
        : text.replaceAllMapped(
            emoji,
            (m) => '<span class="$kXbEmojiClass">${m.group(0)}</span>',
          ),
  );
}

/// 从「完整 HTML 文档」提取可供 flutter_html 渲染的正文片段。
///
/// 知识库（使用教程）正文常是整页 HTML 文档（doctype + html/head/style + body）。
/// flutter_html 不应用 `style` 标签里的 CSS，且会把 `style` / `head` 的源码当成普通文字渲染出来
/// （一大坨 CSS）。本函数：
/// - 取 `body` 内层（无 body 标签则用原文）；
/// - 去除 `style` / `script` / `head` 标签块与 HTML 注释；
/// - 去除后端未替换的模板占位符 `{{...}}`（如非订阅用户的 `{{apple_accounts}}`）。
///
/// 返回的片段交给 flutter_html 渲染 + 页面侧 Style map 还原观感。
String htmlRenderableBody(String input) {
  if (input.isEmpty) return '';
  var s = input;
  // 1. 整页文档 → 取 <body> 内层。
  final body = RegExp(r'<body[^>]*>([\s\S]*?)</body>', caseSensitive: false)
      .firstMatch(s);
  if (body != null) s = body.group(1) ?? s;
  // 2. 去 <style> / <script>（含 body 内联块），否则其源码会被当正文显示。
  s = s.replaceAll(
      RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '');
  s = s.replaceAll(
      RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '');
  // 3. 去残留 <head>…</head>（极少数 body 外标签遗留）与 HTML 注释。
  s = s.replaceAll(
      RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  // 4. 去后端未替换的模板占位符 {{xxx}}（非订阅用户看到的 raw 占位）。
  s = s.replaceAll(RegExp(r'\{\{[^}]*\}\}'), '');
  // 5. 处理内联样式颜色，保证暗/亮两种主题都清晰。
  //    知识库正文是「纯浅色模式」撰写的整页 HTML，标题/正文用了硬编码深色（如 color:#111827、
  //    color:#6b7280），暗色模式下深字压暗底几乎不可见。flutter_html 又不应用 <style> CSS、
  //    无法解析 var()，且内联 style 会覆盖页面 Style map（无 force-override）→ 只能在字符串里处理。
  //    策略（既修不可见标题，又不破坏本就正常的彩色框）：
  //    - 元素**自带背景**（如 background:#fff3cd 警告框、background:#d92e1a 按钮）：color 与背景
  //      成对撰写、自洽，两种主题都清晰 → 整条 style 原样保留。
  //    - 元素**无自带背景**（正文/标题直接压在页面背景上）：删掉其 color 声明 → 回退到页面 Style
  //      map（body=t.on，随主题自适应），其余声明（边框/字号/粗细，如标题红色左边框）保留。
  //    顺带删除残留的 prop:var(...)（flutter_html 无法解析）。
  s = s.replaceAll(RegExp(r'[a-zA-Z-]+\s*:\s*var\([^)]*\)\s*;?'), '');
  s = s.replaceAllMapped(
    RegExp(r'style\s*=\s*"([^"]*)"', caseSensitive: false),
    (m) {
      final decls = m.group(1) ?? '';
      // 自带背景的元素：颜色/背景成对自洽，保留原样。
      if (RegExp(r'background', caseSensitive: false).hasMatch(decls)) {
        return m.group(0)!;
      }
      // 无背景：剥掉 color 声明，回退主题自适应文字色；保留其它声明。
      final kept = decls
          .split(';')
          .where((d) =>
              d.trim().isNotEmpty &&
              !RegExp(r'^\s*color\s*:', caseSensitive: false).hasMatch(d))
          .join(';');
      return kept.isEmpty ? '' : 'style="$kept"';
    },
  );
  return s.trim();
}
