/// W6.4 — 形态 A Walking Skeleton 端到端集成测试（Property 1 / R1.6 / NFR-2.1）。
///
/// 路径：formA 外壳冷启动 → 首页（连接球/速度卡/模式段）→ 切节点 Tab → 切我的 Tab → 登录 sheet。
/// 用 fake 反腐层 + FlClash provider override（无后端/无 VPN 内核），在真实 Android 运行时验证
/// 外壳 + adapter + Tab 全链路不崩、Tab 保活、底栏切换有效。
///
/// **注**：① 完整内核行为等价（VPN 连/断、mode 生效）需真实 core，本冒烟聚焦外壳 + UI 链路；
/// ② bare 容器需补 HomeTab 子树（线路卡）依赖的 FlClash provider override（真 app 由 bootstrap
/// 容器提供），否则子树抛异常被 XbErrorBoundary 兜住 = 看不到内容（这本身证明 R1.7 有效）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/enum/enum.dart' show CoreStatus, ProxyCardType;
import 'package:fl_clash/models/models.dart' show PatchClashConfig, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_speed_card.dart';
import 'package:fl_clash/xboard/shell/widgets/xb_bottom_bar.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';

import '_fake_integration_service.dart';

ProxiesTabState _emptyTab() => const ProxiesTabState(
      groups: [],
      currentGroupName: null,
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakeIntegrationService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({'xb_consent_v1': true});
    service = FakeIntegrationService();
  });

  Widget app(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: XboardAppShell()),
      );

  /// 补齐 HomeTab/NodesTab 子树依赖的 FlClash provider（真 app 由 bootstrap 容器提供）。
  ProviderContainer makeContainer(AuthState auth) => ProviderContainer(
        overrides: [
          xboardServiceProvider.overrideWithValue(service),
          bootstrapReadyProvider.overrideWith(() => _Ready()),
          authStateProvider.overrideWith(() => _Auth(auth)),
          isStartProvider.overrideWith((ref) => false),
          proxiesTabStateProvider.overrideWith((ref) => _emptyTab()),
          patchClashConfigProvider
              .overrideWithBuild((ref, _) => const PatchClashConfig()),
        ],
      );

  /// 点底栏某 Tab（用 XbBottomBar 内的 label，避开页面标题同名歧义）。
  Future<void> tapTab(WidgetTester t, String label) async {
    final tab = find.descendant(
      of: find.byType(XbBottomBar),
      matching: find.text(label),
    );
    await t.tap(tab);
    await t.pumpAndSettle();
  }

  testWidgets('formA 外壳：首页 连接球/速度卡渲染 + 三 Tab 切换 + 保活', (t) async {
    final container = makeContainer(AuthState.authenticated);
    addTearDown(container.dispose);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;

    await t.pumpWidget(app(container));
    await t.pumpAndSettle();

    // 首页：连接球 + 速度卡渲染（HomeTab 子树未进 error boundary = 内核交互正常）。
    expect(find.byType(XbConnectOrb), findsOneWidget);
    expect(find.byType(XbSpeedCard), findsOneWidget);

    // 切节点 → 切我的 → 回首页。
    await tapTab(t, '节点');
    await tapTab(t, '我的');
    await tapTab(t, '首页');

    // 回首页后连接球仍在（IndexedStack 保活，R1.4）。
    expect(find.byType(XbConnectOrb), findsOneWidget);
  });

  testWidgets('formA 游客 → 我的 Tab 登录引导 → 弹登录 sheet（R5.3 渐进登录）', (t) async {
    final container = makeContainer(AuthState.unauthenticated);
    addTearDown(container.dispose);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;

    await t.pumpWidget(app(container));
    await t.pumpAndSettle();

    await tapTab(t, '我的');
    expect(find.text('登录后管理你的套餐与流量'), findsOneWidget);

    // 点登录 → 弹登录 sheet（不全屏拦截，R5.3）。
    await t.tap(find.widgetWithText(FilledButton, '登录 / 注册'));
    await t.pumpAndSettle();
    expect(find.text('注册账号'), findsOneWidget);
    expect(find.text('忘记密码？'), findsOneWidget);
  });
}

class _Ready extends BootstrapReady {
  @override
  bool build() => true;
}

class _Auth extends AuthStateNotifier {
  _Auth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}
