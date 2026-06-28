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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_notice.dart';
import 'package:fl_clash/xboard/providers/notice_provider.dart';
import 'package:fl_clash/xboard/widgets/xb_announcement.dart';

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

/// 假公告（富文本，含标题段/加粗/列表/链接/emoji，覆盖 flutter_html 各路径）。
final _fakeNotices = <XbNotice>[
  XbNotice(
    id: 2,
    title: '🎉 限时活动 · 全场套餐 8 折',
    content: '<div style="font-weight:600;color:#D92E1A">活动详情</div>'
        '<div>即日起至 <b>7 月 5 日</b>，全场套餐享 <b>8 折</b>：</div>'
        '<ul><li>新购 / 续费 / 升级均可参与</li><li>可叠加邀请返佣</li></ul>'
        '<div>详情见 <a href="#">活动页面</a>，祝使用愉快 🚀</div>',
    createdAt: DateTime(2026, 6, 28),
    updatedAt: 1782000000,
  ),
  XbNotice(
    id: 1,
    title: '线路维护通知',
    content: '<div style="font-weight:600;color:#D92E1A">维护时间</div>'
        '<div>6 月 21 日 02:00–04:00 对部分海外线路升级，期间可能短暂波动。</div>'
        '<div>建议错峰使用，给您带来的不便敬请谅解。</div>',
    createdAt: DateTime(2026, 6, 20),
    updatedAt: 1781000000,
  ),
];

XbNoticeState _state({required bool hasUnread}) => XbNoticeState(
      notices: _fakeNotices,
      hasUnread: hasUnread,
      userIdHash: 'testuser',
    );

void main() {
  setUpAll(_loadCjkFont);

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
      await expectLater(find.byType(XbNoticePill),
          matchesGoldenFile('goldens/notice_pill_light.png'));
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
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/notice_sheet_light.png'));
    });

    testWidgets('dark — 不崩 + golden', (t) async {
      await pumpSheet(t, Brightness.dark);
      expect(t.takeException(), isNull);
      expect(find.text('公告'), findsOneWidget);
      expect(find.textContaining('font-weight'), findsNothing);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/notice_sheet_dark.png'));
    });
  });
}
