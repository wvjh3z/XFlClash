library;


import 'package:material_ui/material_ui.dart';
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
import 'package:fl_clash/xboard/providers/notice_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_expiry_card.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

import '../shell/_net_detection_stub.dart';
import '../shell/_fixture_delay_core.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
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
  proxyCardType: ProxyCardType.standard,

);

XbDomainSubscription _sub({bool expired = false}) => XbDomainSubscription(
  email: 'user@example.com',
  uuid: 'uid-golden',
  planName: '标准套餐 · VIP',
  totalBytes: 250 * 1024 * 1024 * 1024,
  usedBytes: 155 * 1024 * 1024 * 1024,
  // A lifetime plan keeps these snapshots independent of wall-clock time.
  // Expiration and reset countdowns have separate focused widget coverage.
  expiredAt: expired ? DateTime(2000, 7, 1, 8, 30) : null,
  nextResetAt: null,
  planId: 1,
);

Future<void> pumpShell(
  WidgetTester tester, {
  required CoreStatus core,
  Size size = const Size(1280, 800),
  AuthState auth = AuthState.authenticated,
  bool expired = false,
  bool mobile = false,
  bool unselected = false,
  XbDomainSubscription? subscription,
  XboardService? service,
  XboardConfig? config,
  DateTime? expiryNow,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  XboardConfig.bind(
    config ?? const XboardConfig(
      subscribeUserAgent: 'x flclash',
      devApiEndpoint: 'https://x',
      devSubscriptionEndpoint: 'https://x',
      debug: false,
      kIsTest: true,
      formA: true,
    ),
  );
  addTearDown(XboardConfig.resetForTest);

  final tab = unselected ? const ProxiesTabState(groups: [],currentGroupName: null,proxyCardType: ProxyCardType.standard) : _tab();
  final container = ProviderContainer(
    overrides: [
      if (expiryNow != null) expiryClockProvider.overrideWithValue(() => expiryNow),
      isMobileViewProvider.overrideWith((ref) => mobile),
      authStateProvider.overrideWith(() => _FakeAuth(auth)),
      // Ordinary shell snapshots model a successful empty notice response,
      // independently of whichever account/commerce service a case injects.
      noticeStateProvider.overrideWith((_) async => XbNoticeState.empty),
      isStartProvider.overrideWith((ref) => core == CoreStatus.connected),
      proxiesTabStateProvider.overrideWith((ref) => tab),
      netDetectionOverride(ip: core == CoreStatus.connected ? '47.243.10.20' : '113.96.10.20', countryCode: core == CoreStatus.connected ? 'HK' : 'CN'),
      fixtureDelayCoreOverride(),
      if (service != null) xboardServiceProvider.overrideWithValue(service),
      userProfileProvider.overrideWith(
        (ref) => Future.value(subscription ?? _sub(expired: expired)),
      ),
      groupsProvider.overrideWithValue(tab.groups),
      selectedMapProvider.overrideWith(
        (ref) => unselected ? const {} : const {'优选': '🇭🇰 香港 IEPL 专线 01', '香港': '🇭🇰 香港 BGP 02'},
      ),
      currentProfileProvider.overrideWith((ref) => null),
      patchClashConfigProvider.overrideWithBuild(
        (ref, _) => const PatchClashConfig(mode: Mode.rule),
      ),
      for (final g in tab.groups) ...[
        selectedProxyNameProvider(g.name).overrideWithValue(g.now),
        proxyNameProvider(g.name).overrideWithValue(null),
        for (final p in g.all)
          delayProvider(
            proxyName: p.name,
            testUrl: g.testUrl,
          ).overrideWithValue(48),
      ],
    ],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value = core;

  final originalErrorBuilder = ErrorWidget.builder;
  try {
    await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(key: const ValueKey('home-golden-window'), child: MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        debugShowCheckedModeBanner: false,
        builder: !mobile || core != CoreStatus.connected ? null : (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const XboardAppShell(),
      )),
    ),
  );
  } finally {
    // Shell installs a process-wide builder at mount; do not leak it across tests.
    ErrorWidget.builder = originalErrorBuilder;
  }
  // Asset decoding uses real asynchronous work; fake clock pumps alone can
  // capture an empty logo. Keep the existing unbranded development asset here;
  // the CLI tests verify each brand is injected into this same path.
  await tester.runAsync(() async {
    await precacheImage(
      const AssetImage('assets/images/icon.png'),
      tester.element(find.byType(XboardAppShell)),
    );
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.text('公告重试', skipOffstage: false), findsNothing,
      reason: '普通业务金图建立在公告读取成功的夹具上；错误交给公告恢复专项验证');
}
