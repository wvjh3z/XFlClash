/// W4.8 — Walking Skeleton 端到端集成测试（真机/模拟器）。
///
/// 路径：主页 R5（游客）→ 登录 R2 → 账号卡 R6 → 退出 R4.5 → 回游客。
/// 用 fake 反腐层（无后端/无 VPN 内核），在真实 Android 运行时验证 UI + provider 全链路。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/pages/xboard_service_home_page.dart';
import 'package:fl_clash/xboard/providers/xboard_connectivity_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/widgets/account_info_card.dart';

import '_fake_integration_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakeIntegrationService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({'xb_consent_v1': true}); // 跳过 consent 弹窗
    service = FakeIntegrationService();
  });

  Widget app() => ProviderScope(
        overrides: [
          xboardServiceProvider.overrideWithValue(service),
          bootstrapReadyProvider.overrideWith(() => _Ready()),
          firstLaunchProvider.overrideWith(() => _NotFirst()),
          isOfflineProvider.overrideWith((ref) => false),
        ],
        child: const MaterialApp(home: XboardServiceHomePage()),
      );

  testWidgets('walking skeleton：游客 → 登录 → 账号卡 → 退出 → 回游客', (t) async {
    await t.pumpWidget(app());
    await t.pumpAndSettle();

    // 1. 游客视图。
    expect(find.text('登录管理你的服务'), findsOneWidget);

    // 2. 点登录进登录页。
    await t.tap(find.widgetWithText(FilledButton, '登录'));
    await t.pumpAndSettle();
    expect(find.text('欢迎回来'), findsOneWidget);

    // 3. 填表登录。
    await t.enterText(find.widgetWithText(TextField, '邮箱'), 'demo@example.com');
    await t.enterText(find.widgetWithText(TextField, '密码'), 'password');
    await t.tap(find.widgetWithText(FilledButton, '登录'));
    await t.pumpAndSettle();

    // 4. 回到主页 + authState 已登录 → 账号卡。
    expect(find.byType(AccountInfoCard), findsOneWidget);
    expect(find.textContaining('GB'), findsWidgets); // 流量
    expect(find.text('退出登录'), findsOneWidget);

    // 5. 退出登录 → 回游客视图。
    await t.tap(find.text('退出登录'));
    await t.pumpAndSettle();
    expect(service.logoutCalls, greaterThanOrEqualTo(1));
    expect(find.text('登录管理你的服务'), findsOneWidget);
  });
}

class _Ready extends BootstrapReady {
  @override
  bool build() => true;
}

class _NotFirst extends FirstLaunch {
  @override
  bool build() => false;
}
