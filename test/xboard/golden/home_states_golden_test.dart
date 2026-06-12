/// 形态 A 首页连接态 golden 核对（游客 / 未连接 / 连接中 / 已连接）。
///
/// 用 CoreStatus + isStart 驱动连接球四态，渲染 golden 跟原型 home(state) 对比。不依赖模拟器。
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
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/home_tab.dart';
import '../shell/_net_detection_stub.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

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

ProxiesTabState _tab() => const ProxiesTabState(
      groups: [
        Group(
          type: GroupType.Selector,
          name: '智能优选',
          now: '香港01', // 已选中节点 → 线路卡展示「香港01 / 当前分组：智能优选」
          all: [Proxy(name: '香港01', type: 'ss')],
        ),
      ],
      currentGroupName: '智能优选',
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

Future<void> pumpHome(
  WidgetTester tester, {
  required AuthState auth,
  required CoreStatus core,
  required bool isStart,
  XbDomainSubscription? sub,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _FakeAuth(auth)),
      isStartProvider.overrideWith((ref) => isStart),
      proxiesTabStateProvider.overrideWith((ref) => _tab()),
      netDetectionOverride(),
      if (sub != null)
        userProfileProvider.overrideWith((ref) => Future.value(sub)),
      groupsProvider.overrideWithValue(const [
        Group(
          type: GroupType.Selector,
          name: '智能优选',
          now: '香港01',
          all: [Proxy(name: '香港01', type: 'ss')],
        ),
      ]),
      selectedMapProvider.overrideWith((ref) => const {'智能优选': '香港01'}),
      currentProfileProvider.overrideWith((ref) => null),
      patchClashConfigProvider
          .overrideWithBuild((ref, _) => const PatchClashConfig(mode: Mode.rule)),
    ],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value = core;

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        home: const Scaffold(
          body: XbBrandTheme(
            brandColor: Color(0xFFD92E1A),
            child: HomeTab(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(_loadCjkFont);

  testWidgets('首页 · 游客 golden', (t) async {
    await pumpHome(t,
        auth: AuthState.unauthenticated,
        core: CoreStatus.disconnected,
        isStart: false);
    expect(t.takeException(), isNull);
    await expectLater(
        find.byType(HomeTab), matchesGoldenFile('goldens/home_guest.png'));
  });

  testWidgets('首页 · 已登录未连接 golden', (t) async {
    await pumpHome(t,
        auth: AuthState.authenticated,
        core: CoreStatus.disconnected,
        isStart: false);
    expect(t.takeException(), isNull);
    await expectLater(
        find.byType(HomeTab), matchesGoldenFile('goldens/home_ready.png'));
  });

  testWidgets('首页 · 已连接 golden', (t) async {
    await pumpHome(t,
        auth: AuthState.authenticated,
        core: CoreStatus.connected,
        isStart: true);
    expect(t.takeException(), isNull);
    await expectLater(
        find.byType(HomeTab), matchesGoldenFile('goldens/home_connected.png'));
  });

  testWidgets('首页 · 套餐到期提醒（剩7天）golden', (t) async {
    final now = DateTime.now();
    await pumpHome(t,
        auth: AuthState.authenticated,
        core: CoreStatus.disconnected,
        isStart: false,
        sub: _subExpiring(now.add(const Duration(days: 7, hours: 12))));
    expect(t.takeException(), isNull);
    await expectLater(find.byType(HomeTab),
        matchesGoldenFile('goldens/home_expiry_7d.png'));
  });

  testWidgets('首页 · 套餐已过期 golden', (t) async {
    final now = DateTime.now();
    await pumpHome(t,
        auth: AuthState.authenticated,
        core: CoreStatus.disconnected,
        isStart: false,
        sub: _subExpiring(now.subtract(const Duration(days: 1))));
    expect(t.takeException(), isNull);
    await expectLater(find.byType(HomeTab),
        matchesGoldenFile('goldens/home_expiry_expired.png'));
  });
}

/// 构造带指定到期时间的订阅（其余字段固定，避免像素漂移）。
XbDomainSubscription _subExpiring(DateTime expiredAt) => XbDomainSubscription(
      email: 'test@example.com',
      uuid: 'uuid-0000',
      planName: '标准套餐',
      totalBytes: 250 * 1024 * 1024 * 1024,
      usedBytes: 50 * 1024 * 1024 * 1024,
      expiredAt: expiredAt,
      planId: 1,
    );
