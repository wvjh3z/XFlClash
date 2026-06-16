/// DEV-ONLY 桌面预览入口（不进正常构建，仅用 `flutter run/build -t` 显式指定）。
///
/// 目的：在 headless Linux 上用 Xvfb + noVNC 把真实的桌面 [XboardAppShell] widget 树
/// 渲染到浏览器，供远程实时审阅 UI（Win/mac/Linux 桌面共用同一份 widget 代码）。
///
/// 它**完全绕开** FlClash 原生初始化（RustLib / globalState / clash 核心 / 真实登录），
/// 改用与 golden 测试同款的 fake provider 注入确定性示例数据，因此一定能渲染、
/// 不依赖能否连 VPN、不依赖后端。数据为示例值，接 API 后由真实 provider 提供。
///
/// 用法：
///   flutter run -d linux -t lib/xboard/dev/desktop_preview_main.dart
/// 或构建后在 Xvfb 中运行产物可执行文件。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show
        PatchClashConfig,
        Group,
        Proxy,
        ProxiesTabState,
        IpInfo,
        NetworkDetectionState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/providers.dart'
    show selectedMapProvider, groupsProvider, currentProfileProvider;
import 'package:fl_clash/xboard/providers/xboard_providers.dart'
    show bootstrapReadyProvider;
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

class _FakeNetworkDetection extends NetworkDetection {
  _FakeNetworkDetection(this._state);
  final NetworkDetectionState _state;
  @override
  NetworkDetectionState build() => _state;
  @override
  void startCheck() {} // no-op：不起真实 Timer / 网络。
}

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
      uuid: 'uid-preview',
      planName: '标准套餐 · VIP',
      totalBytes: 250 * 1024 * 1024 * 1024,
      usedBytes: 155 * 1024 * 1024 * 1024,
      expiredAt: DateTime(2026, 7, 1, 8, 30),
      nextResetAt: DateTime(2026, 6, 20, 11, 17),
      planId: 1,
    );

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  XboardConfig.bind(const XboardConfig(
    subscribeUserAgent: 'x flclash',
    devApiEndpoint: 'https://x',
    devSubscriptionEndpoint: 'https://x',
    debug: false,
    kIsTest: true,
    formA: true,
  ));

  final tab = _tab();
  const detState = NetworkDetectionState(
    isLoading: false,
    ipInfo: IpInfo(ip: '47.243.10.20', countryCode: 'HK'),
  );

  final container = ProviderContainer(overrides: [
    isMobileViewProvider.overrideWith((ref) => false),
    authStateProvider.overrideWith(() => _FakeAuth(AuthState.authenticated)),
    isStartProvider.overrideWith((ref) => true),
    proxiesTabStateProvider.overrideWith((ref) => tab),
    networkDetectionProvider
        .overrideWith(() => _FakeNetworkDetection(detState)),
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
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: XboardAppShell(),
      ),
    ),
  );
}
