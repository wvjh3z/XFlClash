/// W3.6 — HomeTab 组装 + 游客 banner 单测。
///
/// 覆盖：游客态显示登录 banner + 各组件齐全；已登录态隐藏 banner。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show PatchClashConfig, Group, Proxy, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/providers.dart'
    show
        selectedMapProvider,
        groupsProvider,
        currentProfileProvider,
        setupActionProvider,
        SetupAction,
        excludeSSIDsProvider,
        currentSSIDProvider,
        currentGroupsStateProvider;
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/home_tab.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_line_card.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_speed_card.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_mode_segment.dart';
import '../_net_detection_stub.dart';
import '../_fixture_delay_core.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/common/constant.dart' show renderThrottleDuration;
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/xboard/providers/home_latency_provider.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
  void change(AuthState next) => state = next;
}

ProxiesTabState _tab() => const ProxiesTabState(
  groups: [
    Group(
      type: GroupType.Selector,
      hidden: false,
      name: '智能优选',
      all: [Proxy(name: '香港01', type: 'ss')],
    ),
  ],
  currentGroupName: '智能优选',
  proxyCardType: ProxyCardType.standard,
);

ProxiesTabState _emptyTab() => const ProxiesTabState(
  groups: [],
  currentGroupName: null,
  proxyCardType: ProxyCardType.standard,
);

Future<void> pumpHome(
  WidgetTester tester, {
  required AuthState auth,
  ProxiesTabState? tab,
  SetupAction? setup,
  bool running = false,
  bool ready = true,
  bool Function()? runningNow,
  FixtureDelayCore? delayCore,
}) async {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _FakeAuth(auth)),
      isStartProvider.overrideWith((ref) => runningNow?.call() ?? running),
      coreHandlerProvider.overrideWithValue(CoreController.scoped(delayCore ?? FixtureDelayCore())),
      proxiesTabStateProvider.overrideWith((ref) => tab ?? _tab()),
      netDetectionOverride(),
      if (setup != null) setupActionProvider.overrideWith(() => setup),
      excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
      groupsProvider.overrideWithValue(const [
        Group(
          type: GroupType.Selector,
          hidden: false,
          name: '智能优选',
          now: '香港01',
          all: [Proxy(name: '香港01', type: 'ss')],
        ),
      ]),
      selectedMapProvider.overrideWith((ref) => const {'智能优选': '香港01'}),
      currentProfileProvider.overrideWith((ref) => null),
      patchClashConfigProvider.overrideWithBuild(
        (ref, _) => const PatchClashConfig(mode: Mode.rule),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(ready);
  container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: HomeTab())),
    ),
  );
  await tester.pump();
}

class _RecordingSetup extends SetupAction {
  final calls = <bool>[];
  @override
  void build() {}
  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    calls.add(running);
    // End at the native boundary; success followups are covered elsewhere.
    return false;
  }
}

void main() {
  testWidgets('外部已连接、快捷开关和重连各测一轮；无重绘轮询', (tester) async {
    var running = true;
    final core = FixtureDelayCore();
    await pumpHome(tester, auth: AuthState.authenticated, runningNow: () => running, delayCore: core);
    final c = ProviderScope.containerOf(tester.element(find.byType(HomeTab)), listen: false);
    final delay = c.listen(delayProvider(proxyName: '香港01', testUrl: c.read(realTestUrlProvider(null))), (_, _) {});
    addTearDown(delay.close);
    await tester.pump();
    expect(core.calls, 3);
    expect(c.read(homeLatencyProvider).ms, 48);
    await tester.pump(const Duration(seconds: 5));
    expect(core.calls, 3);
    running = false;
    c.invalidate(isStartProvider);
    await tester.pump();
    expect(c.read(homeLatencyProvider).ms, isNull);
    running = true;
    c.invalidate(isStartProvider);
    await tester.pump();
    await tester.pump();
    expect(core.calls, 6);
    c.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    await tester.pump();
    core.sample = 72;
    c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    await tester.pump();
    await tester.pump();
    expect(core.calls, 9);
    await tester.pump(renderThrottleDuration);
    expect(delay.read(), 72);
    expect(core.calls, 9);
  });
  testWidgets('移动首页准备阶段不显示可操作的游客登录邀请', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpHome(tester, auth: AuthState.unauthenticated, ready: false);
    expect(find.text('正在准备服务，请稍候…'), findsOneWidget);
    expect(find.text('首屏无需等待，可先浏览各页面'), findsOneWidget);
    expect(find.text('登录解锁全部功能'), findsNothing);
    expect(tester.widget<XbConnectOrb>(find.byType(XbConnectOrb)).showLock, isFalse);
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeTab)), listen: false);
    container.read(bootstrapReadyProvider.notifier).set(true);
    await tester.pump();
    expect(find.text('登录解锁全部功能'), findsOneWidget);
    expect(find.text('首屏无需等待，可先浏览各页面'), findsNothing);
  });

  for (final brand in ['brand_a', 'brand_b']) {
    for (final width in [450.0, 1200.0]) {
      for (final scenario in [
        'logout',
        'login',
        'login-empty',
        'paused-logout',
      ]) {
        testWidgets('$brand width=$width latest auth without repaint $scenario', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          XboardConfig.bind(
            XboardConfig(
              subscribeUserAgent: 'test',
              devApiEndpoint: 'https://api.example.invalid',
              devSubscriptionEndpoint: 'https://sub.example.invalid',
              debug: false,
              kIsTest: true,
              flavorId: brand,
              formA: true,
            ),
          );
          addTearDown(XboardConfig.resetForTest);
          final loggingIn = scenario.startsWith('login');
          final setup = _RecordingSetup();
          await pumpHome(
            tester,
            auth: loggingIn
                ? AuthState.unauthenticated
                : AuthState.authenticated,
            tab: scenario == 'login-empty' ? _emptyTab() : null,
            setup: setup,
            running: scenario == 'paused-logout',
          );
          final c = ProviderScope.containerOf(
            tester.element(find.byType(HomeTab)),
            listen: false,
          );
          if (scenario == 'paused-logout') {
            c.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';
            await tester.pump();
            expect(find.text('已暂停'), findsOneWidget);
          }
          final latest = loggingIn
              ? AuthState.authenticated
              : AuthState.unauthenticated;
          (c.read(authStateProvider.notifier) as _FakeAuth).change(latest);
          expect(c.read(authStateProvider), latest);
          // Do not pump: exercise the callback installed by the old HomeTab frame.
          await tester.tap(find.byType(XbConnectOrb));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          expect(setup.calls, switch (scenario) {
            'login' => [true],
            'paused-logout' => [false],
            _ => <bool>[],
          });
          expect(
            find.text('请先登录账号后再连接'),
            scenario == 'logout' ? findsOneWidget : findsNothing,
          );
          if (scenario == 'login-empty') {
            expect(find.text('暂未获取可用线路，请检查网络并刷新节点'), findsOneWidget);
            expect(find.text('请检查网络并刷新节点', findRichText: true), findsOneWidget);
            expect(find.text('连接后自动优选', findRichText: true), findsNothing);
          }
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final brand in ['brand_a', 'brand_b']) {
    testWidgets(
      '$brand native direct request leaves mounted home in real smart mode',
      (tester) async {
        XboardConfig.bind(
          XboardConfig(
            subscribeUserAgent: 'test',
            devApiEndpoint: 'https://api.example.invalid',
            devSubscriptionEndpoint: 'https://sub.example.invalid',
            debug: false,
            kIsTest: true,
            flavorId: brand,
            formA: true,
          ),
        );
        addTearDown(XboardConfig.resetForTest);
        await pumpHome(tester, auth: AuthState.authenticated);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HomeTab)),
          listen: false,
        );
        final originalState = tester.state(find.byType(HomeTab));
        container.read(setupActionProvider.notifier).changeMode(Mode.direct);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(tester.state(find.byType(HomeTab)), same(originalState));
        expect(container.read(patchClashConfigProvider).mode, Mode.rule);
        expect(container.read(currentGroupsStateProvider).value, isNotEmpty);
        final scheme = Theme.of(
          tester.element(find.byType(XbModeSegment)),
        ).colorScheme;
        expect(
          tester.widget<Text>(find.text('智能')).style!.color,
          scheme.primary,
        );
        expect(find.textContaining('模式状态异常'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

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
      await pumpHome(tester, auth: AuthState.authenticated, tab: _emptyTab());
      await tester.tap(find.byType(XbConnectOrb));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('暂未获取可用线路，请检查网络并刷新节点'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });
}
