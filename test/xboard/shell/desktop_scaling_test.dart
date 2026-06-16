/// 桌面外壳多分辨率缩放健壮性测试：1080P / 1440P / 4K 逻辑尺寸下渲染整壳并切换三 Tab，
/// 断言无 RenderFlex overflow（framework 在 overflow 时会让测试失败）+ 外壳正常渲染。
///
/// 4K 在系统缩放 150%/200% 下逻辑尺寸 = 1080P（同布局，更清晰）；本测试覆盖
/// 「4K@100% 大逻辑窗口」极端情形，验证居中限宽不溢出、不拉伸破版。
library;

import 'package:flutter/material.dart';
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
import 'package:fl_clash/xboard/providers/xboard_providers.dart'
    show bootstrapReadyProvider;
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';
import 'package:fl_clash/xboard/shell/widgets/xb_responsive.dart';

import '_net_detection_stub.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

final _groups = <Group>[
  const Group(
    type: GroupType.URLTest,
    name: '优选',
    now: '🇭🇰 香港 IEPL 专线 01',
    all: [
      Proxy(name: '🇭🇰 香港 IEPL 专线 01', type: 'ss'),
      Proxy(name: '🇯🇵 东京 IEPL 02', type: 'vmess'),
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
      uuid: 'uid',
      planName: '标准套餐 · VIP',
      totalBytes: 250 * 1024 * 1024 * 1024,
      usedBytes: 155 * 1024 * 1024 * 1024,
      expiredAt: DateTime(2026, 7, 1, 8, 30),
      nextResetAt: DateTime(2026, 6, 20, 11, 17),
      planId: 1,
    );

Future<void> pumpAt(WidgetTester tester, Size size) async {
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
    isMobileViewProvider.overrideWith((ref) => false),
    authStateProvider.overrideWith(() => _FakeAuth(AuthState.authenticated)),
    isStartProvider.overrideWith((ref) => true),
    proxiesTabStateProvider.overrideWith((ref) => tab),
    netDetectionOverride(),
    userProfileProvider.overrideWith((ref) => Future.value(_sub())),
    groupsProvider.overrideWithValue(_groups),
    selectedMapProvider
        .overrideWith((ref) => const {'优选': '🇭🇰 香港 IEPL 专线 01'}),
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
  container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

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
  final sizes = <String, Size>{
    '1080P (1920x1080)': const Size(1920, 1080),
    '1440P (2560x1440)': const Size(2560, 1440),
    '4K@100% (3840x2160)': const Size(3840, 2160),
    // —— Android 平板 / 横屏（宽>600 → 同样走桌面 NavRail 外壳）——
    '安卓手机横屏 (851x393 矮屏)': const Size(851, 393),
    '7寸平板竖屏 (800x1280)': const Size(800, 1280),
    '10寸平板横屏 (1280x800)': const Size(1280, 800),
    '平板横屏矮 (1180x744)': const Size(1180, 744),
  };

  for (final entry in sizes.entries) {
    testWidgets('外壳无溢出 + 三 Tab 渲染 · ${entry.key}', (t) async {
      final eb = ErrorWidget.builder;
      await pumpAt(t, entry.value);
      // 首页渲染。
      expect(find.byType(XboardAppShell), findsOneWidget);
      // 切节点。
      await t.tap(find.text('节点'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(XboardAppShell), findsOneWidget);
      // 切我的。
      await t.tap(find.text('我的'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(find.byType(XboardAppShell), findsOneWidget);
      // 全程无 overflow（framework 会在 overflow 时抛错使测试失败）。
      ErrorWidget.builder = eb;
    });
  }

  // 4K 优化回归守卫：内容限宽策略随可用宽度分级增长（大屏内容更宽，不恒为 1000）。
  test('内容限宽随窗口分级放大（4K 优化策略）', () {
    final base = xbContentMaxWidth(1280); // 1080P / 4K@200% 档
    final wide = xbContentMaxWidth(1800); // 2K@100% 档
    final ultra = xbContentMaxWidth(3000); // 4K@100% 档
    expect(base, 1000);
    expect(wide, greaterThan(base), reason: '宽屏内容应比基准更宽');
    expect(ultra, greaterThan(wide), reason: '超宽屏内容应进一步放大');
  });
}
