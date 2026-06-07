/// W3.6 — HomeTab 组装 + 游客 banner 单测。
///
/// 覆盖：游客态显示登录 banner + 各组件齐全；已登录态隐藏 banner。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show PatchClashConfig, Group, Proxy, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/home_tab.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_line_card.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_speed_card.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_mode_segment.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

ProxiesTabState _tab() => const ProxiesTabState(
      groups: [
        Group(
          type: GroupType.Selector,
          name: '智能优选',
          all: [Proxy(name: '香港01', type: 'ss')],
        ),
      ],
      currentGroupName: '智能优选',
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

ProxiesTabState _emptyTab() => const ProxiesTabState(
      groups: [],
      currentGroupName: null,
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

Future<void> pumpHome(
  WidgetTester tester, {
  required AuthState auth,
  ProxiesTabState? tab,
}) async {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _FakeAuth(auth)),
      isStartProvider.overrideWith((ref) => false),
      proxiesTabStateProvider.overrideWith((ref) => tab ?? _tab()),
      patchClashConfigProvider
          .overrideWithBuild((ref, _) => const PatchClashConfig(mode: Mode.rule)),
    ],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: HomeTab())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('游客态：显示登录 banner + 连接球/速度卡/模式段齐全', (tester) async {
    await pumpHome(tester, auth: AuthState.unauthenticated);
    expect(find.text('登录解锁全部功能'), findsOneWidget);
    expect(find.byType(XbConnectOrb), findsOneWidget);
    expect(find.byType(XbSpeedCard), findsOneWidget);
    expect(find.byType(XbModeSegment), findsOneWidget);
  });

  testWidgets('游客态：显示 MyClient 标题 + 不显示线路卡（原型对齐）', (tester) async {
    await pumpHome(tester, auth: AuthState.unauthenticated);
    expect(find.text('MyClient'), findsOneWidget);
    // 原型 guest 态无当前线路卡（curnode 仅 auth）。
    expect(find.byType(XbLineCard), findsNothing);
    // 游客说明行。
    expect(find.text('登录后开启加密保护'), findsOneWidget);
  });

  testWidgets('已登录态：隐藏登录 banner + 显示线路卡', (tester) async {
    await pumpHome(tester, auth: AuthState.authenticated);
    expect(find.text('登录解锁全部功能'), findsNothing);
    expect(find.byType(XbConnectOrb), findsOneWidget);
    expect(find.byType(XbLineCard), findsOneWidget);
  });

  group('连接拦截', () {
    testWidgets('游客点连接 → 拦截 + 居中提示「请先登录」，不连接', (tester) async {
      await pumpHome(tester, auth: AuthState.unauthenticated);
      await tester.tap(find.byType(XbConnectOrb));
      await tester.pump(); // 触发 toast 插入 overlay
      await tester.pump(const Duration(milliseconds: 250)); // 淡入
      expect(find.text('请先登录账号后再连接'), findsOneWidget);
      // 走完 3s 停留 + 淡出，清理 timer（避免 pending timer 报错）。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('已登录 + 无可用线路点连接 → 拦截 + 提示「无可用线路」，不连接', (tester) async {
      await pumpHome(
        tester,
        auth: AuthState.authenticated,
        tab: _emptyTab(),
      );
      await tester.tap(find.byType(XbConnectOrb));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('当前无可用线路，请前往「节点」刷新或购买套餐'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });
}
