/// C-分支桌面外壳 golden 截图（NavRail + 各 Tab 桌面布局）。
///
/// 渲染完整 [XboardAppShell] 于 1280×800 桌面视图，依次切到 首页 / 节点 / 我的 出图，
/// 供视觉审阅（无图形环境下用 `flutter test --update-goldens` 生成 PNG）。
/// 不依赖真机 / 原生内核：所有内核/账户数据经 provider override 注入。
library;

import 'golden_environment.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';
import 'shell_fixture.dart';

Future<void> expectDesktopGolden(WidgetTester tester, String filename) async {
  await expectXbGolden(
    tester,
    find.byType(XboardAppShell),
    'goldens/$filename',
  );
}


void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('桌面外壳 · 首页（NavRail + 双栏）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.connected);
    await expectDesktopGolden(t, 'desktop_shell_home.png');
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面外壳 · 节点（master-detail）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.connected);
    await t.tap(find.text('节点'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('当前无可用线路'), findsNothing);
    expect(find.text('🇭🇰 香港 IEPL 专线 01', findRichText: true), findsWidgets);
    await expectDesktopGolden(t, 'desktop_shell_nodes.png');
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面外壳 · 我的（双栏）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.connected);
    await t.tap(find.text('我的'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 800)); // 账号卡填充动画跑完
    await t.pumpAndSettle();
    expect(find.textContaining('155.0', findRichText: true), findsWidgets);
    await expectDesktopGolden(t, 'desktop_shell_mine.png');
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面外壳 · 首页 · 1920×1080（4K 优化：内容自适应加宽）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(
      t,
      core: CoreStatus.connected,
      size: const Size(1920, 1080),
    );
    await expectDesktopGolden(t, 'desktop_shell_home_1920.png');
    ErrorWidget.builder = eb;
  });

  // ── B. 游客态三屏（桌面）──
  testWidgets('桌面 · 游客首页（未登录 banner + 锁定球）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(
      t,
      core: CoreStatus.disconnected,
      auth: AuthState.unauthenticated,
    );
    await expectDesktopGolden(t, 'desktop_guest_home.png');
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面 · 游客节点（引导登录）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(
      t,
      core: CoreStatus.disconnected,
      auth: AuthState.unauthenticated,
    );
    await t.tap(find.text('节点'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await expectDesktopGolden(t, 'desktop_guest_nodes.png');
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面 · 游客我的（未登录卡）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(
      t,
      core: CoreStatus.disconnected,
      auth: AuthState.unauthenticated,
    );
    await t.tap(find.text('我的'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await expectDesktopGolden(t, 'desktop_guest_mine.png');
    ErrorWidget.builder = eb;
  });

  // ── C. 首页状态（桌面）──
  testWidgets('桌面 · 首页未连接（已登录待连接）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.disconnected);
    await expectDesktopGolden(t, 'desktop_home_disconnected.png');
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面 · 已过期套餐保留节点空态和续费操作', (t) async {
    final eb = ErrorWidget.builder;
    try {
      await pumpShell(t, core: CoreStatus.disconnected, expired: true);
      await t.tap(find.text('节点'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('当前无可用线路'), findsOneWidget);
      expect(find.text('前往续费 / 购买'), findsOneWidget);
      expect(find.text('🇭🇰 香港 IEPL 专线 01', findRichText: true), findsNothing);
      expect(t.takeException(), isNull);
    } finally {
      ErrorWidget.builder = eb;
    }
  });
}
