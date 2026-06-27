/// 注入「真实后端套餐 content HTML」渲染套餐详情页，验证深/浅模式可读性。
///
/// **背景**：套餐 content 是后端富文本 HTML，曾用 `var(--xxx)` / `linear-gradient`（flutter_html
/// 不支持）→ 渲染掉色/看不清。修复：① 后端 HTML 去 var()/渐变、正文不写死 color；② 客户端
/// `_htmlContent` 给 flutter_html body Style 设 `color: t.on`（随主题）。本测试注入修复后的
/// 真实 HTML，断言：
/// - 不抛异常（flutter_html 不被这段 HTML 噎住）；
/// - 关键文本可见（HTML 被解析渲染，而非当作源码原样显示）；
/// - `meetsGuideline(textContrastGuideline)` —— 浅色 + 深色都满足 WCAG AA 对比度（即「看得清」）。
///
/// 生成/更新 golden：
///   flutter test --update-goldens test/xboard/golden/plan_content_html_test.dart
library;

import 'dart:io';

import 'package:emoji_regex/emoji_regex.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';

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

/// 用户给的真实套餐 content（修复后：去 var()/渐变，正文不写死 color，标题用具体 hex）。
const _realHtml = '''
<div style="font-size:14px;line-height:1.8"><div style="font-weight:600;margin:12px 0 4px;color:#D92E1A">📦 流量明细</div><div>每月 <b>100GB</b> 流量 · 峰值网速 <b>300Mbps</b></div><div style="font-weight:600;margin:12px 0 4px;color:#D92E1A">🔄 重置期限</div><div>✅ 每月购买日自动重置流量</div><div>✅ 提前手动重置 <b style="color:#ce2c2c">12CNY</b>/次（不延长套餐时长）</div><div style="font-weight:600;margin:12px 0 4px;color:#D92E1A">🌐 线路</div><div>✅ 三网 <b>IPEL专线</b> · <b>OMO视频加速节点</b></div><div style="font-weight:600;margin:12px 0 4px;color:#D92E1A">📱 设备</div><div>✅ 仅限个人使用，<b>限5台设备数</b>，禁止分享</div><div style="font-weight:600;margin:12px 0 4px;color:#D92E1A">📺 支持平台</div><div>✅ Netflix / Disney+ / Youtube / TikTok / Google / ChatGPT 等</div><div style="font-weight:600;margin:12px 0 4px;color:#e05252">⚠️ 注意</div><div>❌ <b style="color:#ce2c2c">新疆／海外地区请勿购买 · 无退款，介意勿买</b></div></div>
''';

const _plan = PlanItem(
  id: 1,
  name: '轻量套餐',
  description: _realHtml,
  transferEnableGb: 100,
  prices: [
    PricePlan(period: XbPlanPeriod.monthly, amountYuan: 10.00),
    PricePlan(period: XbPlanPeriod.yearly, amountYuan: 98.00),
  ],
);

void main() {
  setUpAll(_loadCjkFont);

  Future<void> pumpPage(
    WidgetTester tester, {
    required double textScale,
    required Brightness brightness,
  }) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, brightness: brightness),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: const PlanDetailPage(plan: _plan),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('套餐 content HTML 渲染（真实后端数据注入）', () {
    testWidgets('light 1.0 — 不崩 + 文本可见 + 对比度 + 字体分流 + golden', (t) async {
      await pumpPage(t, textScale: 1.0, brightness: Brightness.light);
      expect(t.takeException(), isNull);
      // HTML 被解析渲染（关键文本作为可见文字出现，而非源码原样）。
      expect(find.textContaining('流量明细'), findsWidgets);
      expect(find.textContaining('新疆'), findsWidgets);
      // 源码标签不应作为可见文字泄漏。
      expect(find.textContaining('font-weight'), findsNothing);
      // 核心断言：数字 span 不用 Twemoji（否则数字渲染成不可见 COLR 基字）；emoji span 用 Twemoji。
      _checkSpanFonts(t);
      await expectLater(find.byType(PlanDetailPage),
          matchesGoldenFile('goldens/plan_content_html_light.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });

    testWidgets('dark 1.0 — 不崩 + 文本可见 + 对比度 + golden', (t) async {
      await pumpPage(t, textScale: 1.0, brightness: Brightness.dark);
      expect(t.takeException(), isNull);
      expect(find.textContaining('流量明细'), findsWidgets);
      expect(find.textContaining('新疆'), findsWidgets);
      expect(find.textContaining('font-weight'), findsNothing);
      _checkSpanFonts(t);
      await expectLater(find.byType(PlanDetailPage),
          matchesGoldenFile('goldens/plan_content_html_dark.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });

    testWidgets('2.0 放大无溢出', (t) async {
      await pumpPage(t, textScale: 2.0, brightness: Brightness.light);
      expect(t.takeException(), isNull);
    });
  });
}

/// 遍历 PlanDetailPage 内所有 RichText 的 InlineSpan，断言：
/// - 含数字的文本 span **不**用 Twemoji（数字走默认字体 → 可见）；
/// - emoji span **用** Twemoji（跨端一致）。
void _checkSpanFonts(WidgetTester t) {
  final emoji = emojiRegex();
  var sawDigit = false;
  var sawEmoji = false;
  for (final rt in t.widgetList<RichText>(find.byType(RichText))) {
    rt.text.visitChildren((span) {
      if (span is TextSpan && span.text != null && span.text!.isNotEmpty) {
        final s = span.text!;
        final font = span.style?.fontFamily;
        final isEmoji = emoji.hasMatch(s);
        if (isEmoji) {
          sawEmoji = true;
          expect(font, 'Twemoji', reason: 'emoji span "$s" 应使用 Twemoji');
        } else if (RegExp(r'[0-9]').hasMatch(s)) {
          // 非 emoji 的数字文本 span：绝不能落到 Twemoji（否则数字不可见）。
          sawDigit = true;
          expect(font, isNot('Twemoji'),
              reason: '数字 span "$s" 不应使用 Twemoji（会被吃成不可见 COLR 基字）');
        }
      }
      return true;
    });
  }
  expect(sawDigit, isTrue, reason: '应渲染到含数字的文本 span（如 100GB/12CNY）');
  expect(sawEmoji, isTrue, reason: '应渲染到 emoji span（如 📦）');
}
