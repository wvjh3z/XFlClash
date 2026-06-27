/// 注入「官方客户端」分类教程的真实正文结构，渲染教程详情页，验证深/浅模式渲染与可读性。
///
/// 客户端只展示后端知识库「官方客户端」分类（_kTutorialCategory）。本测试用脱敏但保留真实
/// 结构的正文（标题红左边框 / 浅底提示框 + 内部彩色 <b> / .apple-card + var(--muted) / emoji /
/// 数字；去真实账号与 <img>），经教程详情页真实管线（htmlRenderableBody → wrapEmojiForHtml →
/// flutter_html Style map）渲染，断言：
/// - 不抛异常；
/// - 数字 span 不用 Twemoji（emoji-only 修复后数字可见）；
/// - meetsGuideline(textContrastGuideline) 浅 + 深都满足 WCAG AA（即「看得清」）。
///   ⚠️ 重点暴露：浅底提示框（background 被 htmlRenderableBody 保留）但内部文字色被剥离 →
///   深色模式下 body=t.on（浅色）压在浅底上 → 可能低对比。
library;

import 'dart:io';

import 'package:emoji_regex/emoji_regex.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_tutorial.dart';
import 'package:fl_clash/xboard/pages/tutorial_detail_page.dart';
import 'package:fl_clash/xboard/providers/tutorial_provider.dart';

const _cjkFontPaths = [
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/System/Library/Fonts/PingFang.ttc',
];

Future<void> _loadCjkFont() async {
  for (final path in _cjkFontPaths) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final bytes = await f.readAsBytes();
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return;
    } catch (_) {}
  }
}

/// 脱敏正文：保留 id=21「官方客户端」教程的真实 HTML 结构（去账号/img）。
const _body = '''
<div style="font-size:15px;line-height:1.8;color:#111827">
  <div style="color:#6b7280;font-size:14px;margin:0 0 4px">iOS 12+ · 订阅导入与常用设置</div>
  <div style="font-size:18px;font-weight:700;color:#111827;border-left:4px solid #d92e1a;padding-left:10px;margin:22px 0 10px">应用简介</div>
  <p style="margin:10px 0"><b>Shadowrocket</b> 是 iOS 代理软件，支持 iOS 12 及以上。</p>
  <div style="background:#fbeae7;border:1px solid #f1c4bd;border-radius:12px;padding:12px 14px;margin:14px 0">
    <b style="color:#d92e1a">重要提示：</b>请关闭并后台退出其他代理软件，多个不能同时使用。
  </div>
  <div style="background:#fff0f0;border:2px solid #dc2626;border-radius:12px;padding:14px 16px;margin:12px 0;line-height:1.85">
    <div style="font-weight:700;color:#dc2626;margin-bottom:6px">⚠️ 重要警告</div>
    ① 仅在 <b style="color:#dc2626">App Store</b> 登录，<b style="color:#dc2626">切勿登录 iCloud</b><br/>
    ② 第一个选 <b>"其他选项"</b>，第二个选 <b>"不升级"</b>
  </div>
  <div style="background:#fff3cd;border:1px solid #ffc107;border-radius:8px;padding:12px 16px;margin:12px 0;color:#856404;font-size:14px">
    ⚠️ 以下内容仅限<b>有效订阅用户</b>查看，请先购买套餐。
  </div>
  <div class="apple-card"><div class="header">📱 共享 Apple ID #1 <span class="status-ok">● 可用</span><span style="font-size:13px;color:var(--muted);margin-left:8px">美国</span></div><div class="row"><div><div class="label">账号</div><div class="value">ex***1@example.com</div></div><button class="copy-btn" data-original-onclick="copy('example001@example.com')">复制</button></div><div class="row"><div><div class="label">密码</div><div class="value">PZ***B</div></div><button class="copy-btn" data-original-onclick="copy('PZjpPMNt8B')">复制</button></div><div style="font-size:14px;color:var(--muted);margin-top:8px">最后检测：2026-06-27 19:09:43</div></div>
  <div style="background:#f8f9fa;border:1px solid #e5e7eb;border-radius:12px;padding:14px 16px;margin:12px 0">
    <div style="font-weight:700;margin-bottom:8px">🔗 更多共享 Apple ID</div>
    <a href="https://example.com/" style="display:inline-block;padding:8px 16px;background:#d92e1a;color:#ffffff;border-radius:6px">前往共享 ID 平台 →</a>
  </div>
</div>
''';

XbTutorialDetail get _detail => XbTutorialDetail(
      id: 21,
      title: '测试测试',
      body: _body,
      updatedAt: DateTime(2026, 6, 27, 19, 9),
    );

void main() {
  setUpAll(_loadCjkFont);

  Future<void> pumpPage(WidgetTester t, {required Brightness brightness}) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(
      ProviderScope(
        overrides: [
          tutorialDetailProvider(21).overrideWith((ref) async => _detail),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, brightness: brightness),
          home: const TutorialDetailPage(id: 21),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  group('教程详情（官方客户端分类）真实正文渲染', () {
    testWidgets('light — 不崩 + 数字字体 + 对比度', (t) async {
      await pumpPage(t, brightness: Brightness.light);
      expect(t.takeException(), isNull);
      expect(find.textContaining('应用简介', findRichText: true), findsWidgets);
      _checkSpanFonts(t);
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });

    testWidgets('dark — 不崩 + 数字字体 + 对比度（暴露浅底框文字可读性）', (t) async {
      await pumpPage(t, brightness: Brightness.dark);
      expect(t.takeException(), isNull);
      expect(find.textContaining('应用简介', findRichText: true), findsWidgets);
      _checkSpanFonts(t);
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });

    testWidgets('apple-card 复制按钮复制完整值（脱敏 .value 不影响）', (t) async {
      // 拦截剪贴板平台调用，断言复制的是 data-original-onclick 里的完整值。
      final copied = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpPage(t, brightness: Brightness.light);
      expect(t.takeException(), isNull);
      // 渲染出复制按钮（每个账号/密码各一个）。
      final btns = find.widgetWithText(OutlinedButton, '复制');
      expect(btns, findsNWidgets(2));
      // 按钮在 ListView 滚动区外 → 先滚到可见再点（否则 tap 不命中）。
      await t.ensureVisible(btns.first);
      await t.pumpAndSettle();
      await t.tap(btns.first);
      await t.pumpAndSettle();
      expect(copied, contains('example001@example.com'));
    });
  });
}

void _checkSpanFonts(WidgetTester t) {
  final emoji = emojiRegex();
  for (final rt in t.widgetList<RichText>(find.byType(RichText))) {
    rt.text.visitChildren((span) {
      if (span is TextSpan && span.text != null && span.text!.isNotEmpty) {
        final s = span.text!;
        if (emoji.hasMatch(s)) {
          expect(span.style?.fontFamily, 'Twemoji',
              reason: 'emoji span "$s" 应使用 Twemoji');
        } else if (RegExp(r'[0-9]').hasMatch(s)) {
          expect(span.style?.fontFamily, isNot('Twemoji'),
              reason: '数字 span "$s" 不应使用 Twemoji');
        }
      }
      return true;
    });
  }
}
