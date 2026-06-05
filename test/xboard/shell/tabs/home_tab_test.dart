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

Future<void> pumpHome(WidgetTester tester, {required AuthState auth}) async {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _FakeAuth(auth)),
      isStartProvider.overrideWith((ref) => false),
      proxiesTabStateProvider.overrideWith((ref) => _tab()),
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

  testWidgets('已登录态：隐藏登录 banner', (tester) async {
    await pumpHome(tester, auth: AuthState.authenticated);
    expect(find.text('登录解锁全部功能'), findsNothing);
    expect(find.byType(XbConnectOrb), findsOneWidget);
  });
}
