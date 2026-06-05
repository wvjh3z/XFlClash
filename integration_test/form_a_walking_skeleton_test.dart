/// W6.4 — 形态 A Walking Skeleton 端到端集成测试（Property 1 / R1.6 / NFR-2.1）。
///
/// 路径：formA 外壳冷启动 → 首页（连接球/速度卡/模式段）→ 切节点 Tab → 切我的 Tab → 登录 sheet。
/// 用 fake 反腐层（无后端/无 VPN 内核），在真实 Android 运行时验证外壳 + adapter + Tab 全链路
/// 不崩、Tab 保活、底栏切换有效。
///
/// **注**：完整内核行为等价（VPN 连/断、mode 生效）需真实 core，本冒烟聚焦外壳 + UI 链路；
/// adapter 读路径一致性已由 test/xboard/shell/adapters/ 单测覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/enum/enum.dart' show CoreStatus;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_speed_card.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';

import '_fake_integration_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakeIntegrationService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({'xb_consent_v1': true});
    service = FakeIntegrationService();
  });

  Widget app(ProviderContainer container) =>
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: XboardAppShell()),
      );

  testWidgets('formA 外壳：首页 → 节点 → 我的 三 Tab 切换 + 连接球/速度卡渲染', (t) async {
    final container = ProviderContainer(
      overrides: [
        xboardServiceProvider.overrideWithValue(service),
        bootstrapReadyProvider.overrideWith(() => _Ready()),
        isStartProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;

    await t.pumpWidget(app(container));
    await t.pumpAndSettle();

    // 首页：连接球 + 速度卡。
    expect(find.byType(XbConnectOrb), findsOneWidget);
    expect(find.byType(XbSpeedCard), findsOneWidget);

    // 切节点 Tab。
    await t.tap(find.text('节点'));
    await t.pumpAndSettle();

    // 切我的 Tab。
    await t.tap(find.text('我的'));
    await t.pumpAndSettle();
    expect(find.text('我的'), findsWidgets);

    // 切回首页：连接球仍在（IndexedStack 保活，R1.4）。
    await t.tap(find.text('首页'));
    await t.pumpAndSettle();
    expect(find.byType(XbConnectOrb), findsOneWidget);
  });

  testWidgets('formA 游客 → 我的 Tab 登录引导 → 弹登录 sheet', (t) async {
    final container = ProviderContainer(
      overrides: [
        xboardServiceProvider.overrideWithValue(service),
        bootstrapReadyProvider.overrideWith(() => _Ready()),
        authStateProvider.overrideWith(() => _Guest()),
        isStartProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;

    await t.pumpWidget(app(container));
    await t.pumpAndSettle();

    await t.tap(find.text('我的'));
    await t.pumpAndSettle();
    expect(find.text('登录后管理你的套餐与流量'), findsOneWidget);

    // 点登录 → 弹登录 sheet。
    await t.tap(find.widgetWithText(FilledButton, '登录 / 注册'));
    await t.pumpAndSettle();
    expect(find.text('注册账号'), findsOneWidget);
  });
}

class _Ready extends BootstrapReady {
  @override
  bool build() => true;
}

class _Guest extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.unauthenticated;
}
