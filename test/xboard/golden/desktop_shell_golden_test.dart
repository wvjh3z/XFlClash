/// C-分支桌面外壳 golden 截图（NavRail + 各 Tab 桌面布局）。
///
/// 渲染完整 [XboardAppShell] 于 1280×800 桌面视图，依次切到 首页 / 节点 / 我的 出图，
/// 供视觉审阅（无图形环境下用 `flutter test --update-goldens` 生成 PNG）。
/// 不依赖真机 / 原生内核：所有内核/账户数据经 provider override 注入。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show PatchClashConfig, Group, Proxy, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/providers.dart'
    show selectedMapProvider, groupsProvider, currentProfileProvider;
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';

import '../shell/_net_detection_stub.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

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

/// 两个分组（优选 url-test + 香港 selector），各带节点，供节点页 master-detail 双列渲染。
final _groups = <Group>[
  const Group(
    type: GroupType.URLTest,
    name: '优选',
    now: '🇭🇰 香港 IEPL 专线 01',
    all: [
      Proxy(name: '🇭🇰 香港 IEPL 专线 01', type: 'ss'),
      Proxy(name: '🇯🇵 东京 IEPL 02', type: 'vmess'),
      Proxy(name: '🇸🇬 新加坡 01', type: 'ss'),
      Proxy(name: '🇺🇸 洛杉矶 GIA', type: 'trojan'),
    ],
  ),
  const Group(
    type: GroupType.Selector,
    name: '香港',
    now: '🇭🇰 香港 BGP 02',
    all: [
      Proxy(name: '🇭🇰 香港 BGP 02', type: 'ss'),
      Proxy(name: '🇭🇰 香港 IPLC 03', type: 'ss'),
    ],
  ),
];

ProxiesTabState _tab() => ProxiesTabState(
      groups: _groups,
      currentGroupName: '优选',
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

XbDomainSubscription _sub() => XbDomainSubscription(
      email: 'user@example.com',
      uuid: 'uid-golden',
      planName: '标准套餐 · VIP',
      totalBytes: 250 * 1024 * 1024 * 1024,
      usedBytes: 155 * 1024 * 1024 * 1024,
      expiredAt: DateTime(2026, 7, 1, 8, 30),
      nextResetAt: DateTime(2026, 6, 20, 11, 17),
      planId: 1,
    );

Future<void> pumpShell(WidgetTester tester,
    {required CoreStatus core,
    Size size = const Size(1280, 800),
    AuthState auth = AuthState.authenticated}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  XboardConfig.bind(const XboardConfig(
    subscribeUserAgent: 'x flclash',
    devApiEndpoint: 'https://x',
    devSubscriptionEndpoint: 'https://x',
    debug: false,
    kIsTest: true,
    formA: true,
  ));
  addTearDown(XboardConfig.resetForTest);

  final tab = _tab();
  final container = ProviderContainer(overrides: [
    isMobileViewProvider.overrideWith((ref) => false), // 桌面视图。
    authStateProvider.overrideWith(() => _FakeAuth(auth)),
    isStartProvider.overrideWith((ref) => core == CoreStatus.connected),
    proxiesTabStateProvider.overrideWith((ref) => tab),
    netDetectionOverride(),
    userProfileProvider.overrideWith((ref) => Future.value(_sub())),
    groupsProvider.overrideWithValue(_groups),
    selectedMapProvider.overrideWith(
        (ref) => const {'优选': '🇭🇰 香港 IEPL 专线 01', '香港': '🇭🇰 香港 BGP 02'}),
    currentProfileProvider.overrideWith((ref) => null),
    patchClashConfigProvider
        .overrideWithBuild((ref, _) => const PatchClashConfig(mode: Mode.rule)),
    for (final g in tab.groups) ...[
      selectedProxyNameProvider(g.name).overrideWithValue(g.now),
      proxyNameProvider(g.name).overrideWithValue(null),
      for (final p in g.all)
        delayProvider(proxyName: p.name, testUrl: g.testUrl)
            .overrideWithValue(48),
    ],
  ]);
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value = core;

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: XboardAppShell(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(_loadCjkFont);

  testWidgets('桌面外壳 · 首页（NavRail + 双栏）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.connected);
    await expectLater(find.byType(XboardAppShell),
        matchesGoldenFile('goldens/desktop_shell_home.png'));
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面外壳 · 节点（master-detail）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.connected);
    await t.tap(find.text('节点'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(XboardAppShell),
        matchesGoldenFile('goldens/desktop_shell_nodes.png'));
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面外壳 · 我的（双栏）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.connected);
    await t.tap(find.text('我的'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 800)); // 账号卡填充动画跑完
    await expectLater(find.byType(XboardAppShell),
        matchesGoldenFile('goldens/desktop_shell_mine.png'));
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面外壳 · 首页 · 1920×1080（4K 优化：内容自适应加宽）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.connected, size: const Size(1920, 1080));
    await expectLater(find.byType(XboardAppShell),
        matchesGoldenFile('goldens/desktop_shell_home_1920.png'));
    ErrorWidget.builder = eb;
  });

  // ── B. 游客态三屏（桌面）──
  testWidgets('桌面 · 游客首页（未登录 banner + 锁定球）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t,
        core: CoreStatus.disconnected, auth: AuthState.unauthenticated);
    await expectLater(find.byType(XboardAppShell),
        matchesGoldenFile('goldens/desktop_guest_home.png'));
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面 · 游客节点（引导登录）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t,
        core: CoreStatus.disconnected, auth: AuthState.unauthenticated);
    await t.tap(find.text('节点'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(XboardAppShell),
        matchesGoldenFile('goldens/desktop_guest_nodes.png'));
    ErrorWidget.builder = eb;
  });

  testWidgets('桌面 · 游客我的（未登录卡）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t,
        core: CoreStatus.disconnected, auth: AuthState.unauthenticated);
    await t.tap(find.text('我的'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(XboardAppShell),
        matchesGoldenFile('goldens/desktop_guest_mine.png'));
    ErrorWidget.builder = eb;
  });

  // ── C. 首页状态（桌面）──
  testWidgets('桌面 · 首页未连接（已登录待连接）', (t) async {
    final eb = ErrorWidget.builder;
    await pumpShell(t, core: CoreStatus.disconnected);
    await expectLater(find.byType(XboardAppShell),
        matchesGoldenFile('goldens/desktop_home_disconnected.png'));
    ErrorWidget.builder = eb;
  });
}
