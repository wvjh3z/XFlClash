/// 注入假公告数据，golden 验证「有新公告」胶囊 + 公告弹窗（flutter_html 富文本）。
///
/// **不连后端**：用 [noticeStateProvider] override 注入假 [XbNoticeState]（胶囊），
/// 直接调 [showXbNoticeSheet] 注入假 [XbNotice] 列表（弹窗）。验证：
/// - 胶囊：有未读 → 显示；无未读 → 不占位；
/// - 弹窗：富文本正文被 flutter_html 解析渲染（关键文本可见、源码标签不泄漏、不抛异常）；
/// - 深/浅模式 golden 锁定观感。
///
/// 生成/更新 golden：
///   flutter test --update-goldens test/xboard/golden/notice_content_html_test.dart
library;

import 'golden_environment.dart';
import 'shell_fixture.dart';
import 'package:fl_clash/enum/enum.dart' show CoreStatus;
import 'package:fl_clash/xboard/shell/tabs/home/home_tab.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_html/flutter_html.dart';

import 'package:fl_clash/xboard/models/xb_notice.dart';
import 'package:fl_clash/xboard/providers/notice_provider.dart';
import 'package:fl_clash/xboard/widgets/xb_announcement.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;

/// 假公告（富文本，含标题段/加粗/列表/链接/emoji，覆盖 flutter_html 各路径）。
final _fakeNotices = <XbNotice>[
  XbNotice(
    id: 2,
    title: '🎉 限时活动 · 全场套餐 8 折',
    content: '<h4>活动详情</h4>'
        '<p>感谢一路支持！即日起至 <strong>7 月 5 日</strong>，全场套餐享 <strong>8 折</strong>：</p>'
        '<ul><li>新购 / 续费 / 升级均可参与</li><li>可叠加邀请返佣</li></ul>'
        '<p>详情见 <a href="#">活动页面</a>，祝使用愉快 🚀</p>',
    createdAt: DateTime(2026, 6, 28),
    updatedAt: 1782000000,
  ),
  XbNotice(
    id: 1,
    title: '线路维护通知',
    content: '<h4>维护时间</h4>'
        '<p>6 月 21 日 <code>02:00–04:00</code> 对部分海外线路升级，期间可能短暂波动。</p>'
        '<blockquote>建议错峰使用，给您带来的不便敬请谅解。</blockquote>',
    createdAt: DateTime(2026, 6, 20),
    updatedAt: 1781000000,
  ),
];

XbNoticeState _state({required bool hasUnread}) => XbNoticeState(
      notices: _fakeNotices,
      hasUnread: hasUnread,
      userIdHash: 'testuser',
    );

void _checkNoticeSpans(WidgetTester tester) {
  final styles = <String, TextStyle>{};
  void walk(InlineSpan span, TextStyle parent) {
    if (span is! TextSpan) return;
    final effective = parent.merge(span.style);
    final text = span.text?.trim();
    if (text != null && text.isNotEmpty) styles[text] = effective;
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, effective);
    }
  }
  final html = find.byType(Html);
  for (final rich in tester.widgetList<RichText>(
    find.descendant(of: html, matching: find.byType(RichText)),
  )) {
    walk(rich.text, const TextStyle());
  }
  final palette = XbTokens.of(tester.element(html.first));
  final body = styles['新购 / 续费 / 升级均可参与']!;
  expect(body.fontSize, 13);
  expect(body.height, 1.65);
  expect(body.color, palette.on);
  expect(styles['7 月 5 日']!.fontWeight, FontWeight.w700);
  expect(styles['维护时间']!.fontSize, 13.5);
  final code = styles['02:00–04:00']!;
  expect(code.fontFamily, 'monospace');
  expect(code.fontSize, 12);
  final quote = styles['建议错峰使用，给您带来的不便敬请谅解。']!;
  expect(quote.color, palette.onv);
  expect(quote.height, 1.65);
  final link = styles['活动页面']!.color!.computeLuminance();
  final bg = palette.sf2.computeLuminance();
  expect(((link > bg ? link : bg) + .05) / ((link < bg ? link : bg) + .05),
      greaterThanOrEqualTo(4.5));
}

void main() {
  setUpAll(loadGoldenFonts);

  void sizePhone(WidgetTester t) {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Widget app({
    required Widget home,
    required Brightness brightness,
    bool hasUnread = true,
  }) =>
      ProviderScope(
        overrides: [
          noticeStateProvider
              .overrideWith((ref) async => _state(hasUnread: hasUnread)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, brightness: brightness),
          home: home,
        ),
      );

  group('公告胶囊（XbNoticePill，注入假数据）', () {
    testWidgets('有未读 → 显示胶囊 + golden（light）', (t) async {
      sizePhone(t);
      await t.pumpWidget(app(
        brightness: Brightness.light,
        home: const Scaffold(body: Center(child: XbNoticePill())),
      ));
      await t.pumpAndSettle();
      expect(find.text('有新公告'), findsOneWidget);
      await expectXbGolden(t, find.byType(XbNoticePill), 'goldens/notice_pill_light.png');
    });

    testWidgets('无未读 → 胶囊不占位', (t) async {
      sizePhone(t);
      await t.pumpWidget(app(
        brightness: Brightness.light,
        hasUnread: false,
        home: const Scaffold(body: Center(child: XbNoticePill())),
      ));
      await t.pumpAndSettle();
      expect(find.text('有新公告'), findsNothing);
    });
  });

  group('公告弹窗（showXbNoticeSheet，注入假数据）', () {
    Future<void> pumpSheet(WidgetTester t, Brightness brightness) async {
      if (brightness == Brightness.light) {
        await pumpShell(t, core: CoreStatus.connected, mobile:true, size:const Size(390,844));
        showXbNoticeSheet(t.element(find.byType(HomeTab)), _fakeNotices);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        return;
      }
      sizePhone(t);
      await t.pumpWidget(app(
        brightness: brightness,
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showXbNoticeSheet(ctx, _fakeNotices),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    testWidgets('light — 不崩 + 富文本渲染 + golden', (t) async {
      await pumpSheet(t, Brightness.light);
      expect(t.takeException(), isNull);
      // 标题 + 富文本被解析渲染（关键文本作为可见文字出现）。
      expect(find.text('公告'), findsOneWidget);
      expect(find.textContaining('活动详情'), findsWidgets);
      expect(find.textContaining('维护时间'), findsWidgets);
      // HTML 源码标签不应作为可见文字泄漏。
      expect(find.textContaining('font-weight'), findsNothing);
      expect(find.textContaining('<div'), findsNothing);
      _checkNoticeSpans(t);
      await expectXbGolden(t, find.byType(MaterialApp), 'goldens/notice_sheet_light.png');
    });

    testWidgets('dark — 不崩 + golden', (t) async {
      await pumpSheet(t, Brightness.dark);
      expect(t.takeException(), isNull);
      expect(find.text('公告'), findsOneWidget);
      expect(find.textContaining('font-weight'), findsNothing);
      _checkNoticeSpans(t);
      await expectXbGolden(t, find.byType(MaterialApp), 'goldens/notice_sheet_dark.png');
    });

    testWidgets('窄屏长公告可滚到末尾，关闭键仍可操作', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(320, 640);
      addTearDown(t.view.reset);
      final notice = XbNotice(
        id: 30,
        title: '维护说明',
        content: '${List.filled(35, '<p>维护期间请留意通知。</p>').join()}'
            '<blockquote>末尾附件编号 <code>A-31</code></blockquote>',
        createdAt: DateTime(2026, 6, 20),
        updatedAt: 1781000000,
      );
      await t.pumpWidget(app(
        brightness: Brightness.dark,
        home: Builder(builder: (ctx) => Scaffold(body: TextButton(
          onPressed: () => showXbNoticeSheet(ctx, [notice]),
          child: const Text('open'),
        ))),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final last = find.text('A-31', findRichText: true);
      expect(last.hitTestable(), findsNothing);
      final scroll = find.ancestor(of: last.first, matching: find.byType(Scrollable)).first;
      await t.scrollUntilVisible(last.first, 320, scrollable: scroll);
      expect(last.hitTestable(), findsWidgets);
      await t.tap(find.text('我知道了'));
      await t.pumpAndSettle();
      expect(find.text('公告'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}
