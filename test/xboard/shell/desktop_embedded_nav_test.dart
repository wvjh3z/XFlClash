/// 桌面嵌套 Navigator 回归守卫（C-分支）：桌面点「我的→设置」后，子页渲染在内容区，
/// 左侧 NavRail **仍可见**（不再全屏跳转盖掉 NavRail）；返回后回到「我的」。
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
import 'package:fl_clash/xboard/shell/widgets/xb_nav_rail.dart';

import '_net_detection_stub.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

void main() {
  testWidgets('桌面：我的→设置 子页嵌入内容区，NavRail 保留', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    XboardConfig.bind(const XboardConfig(
        subscribeUserAgent: 'x', devApiEndpoint: 'https://x',
        devSubscriptionEndpoint: 'https://x', debug: false,
        kIsTest: true, formA: true));
    addTearDown(XboardConfig.resetForTest);

    const groups = [
      Group(type: GroupType.URLTest, name: '优选', now: 'a',
          all: [Proxy(name: 'a', type: 'ss')]),
    ];
    final container = ProviderContainer(overrides: [
      isMobileViewProvider.overrideWith((ref) => false),
      authStateProvider.overrideWith(() => _FakeAuth(AuthState.authenticated)),
      isStartProvider.overrideWith((ref) => true),
      proxiesTabStateProvider.overrideWith((ref) => const ProxiesTabState(
          groups: groups, currentGroupName: '优选',
          proxyCardType: ProxyCardType.expand, columns: 2)),
      netDetectionOverride(),
      userProfileProvider.overrideWith((ref) => Future.value(
          XbDomainSubscription(
              email: 'u@e.com', uuid: 'x', planName: '标准套餐 · VIP',
              totalBytes: 250 * 1024 * 1024 * 1024,
              usedBytes: 100 * 1024 * 1024 * 1024,
              expiredAt: DateTime(2026, 7, 1), planId: 1))),
      groupsProvider.overrideWithValue(groups),
      selectedMapProvider.overrideWith((ref) => const {'优选': 'a'}),
      currentProfileProvider.overrideWith((ref) => null),
      patchClashConfigProvider
          .overrideWithBuild((ref, _) => const PatchClashConfig(mode: Mode.rule)),
    ]);
    addTearDown(container.dispose);
    container.read(bootstrapReadyProvider.notifier).set(true);
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

    final eb = ErrorWidget.builder;
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: XboardAppShell()),
    ));
    await t.pump();
    // 切到「我的」。
    await t.tap(find.text('我的'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(XbNavRail), findsOneWidget);

    // 点「设置」列表项（我的 应用组,非 NavRail 项）→ push 子页到内容区。
    await t.tap(find.text('设置').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    // 关键断言：NavRail 仍在（子页只覆盖内容区，没盖掉 NavRail）。
    expect(find.byType(XbNavRail), findsOneWidget, reason: '子页不应盖掉 NavRail');
    // 设置页内容已显示（分组标签）。
    expect(find.text('更多'), findsOneWidget);

    ErrorWidget.builder = eb;
  });
}
