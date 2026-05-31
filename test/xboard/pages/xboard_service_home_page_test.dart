/// W4.1 — R5 XboardServiceHomePage：bootstrapReady gate / 首次离线 / consent / authState 分流。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' hide AuthState;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/xboard_service_home_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_connectivity_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/account_info_card.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  late _MockService service;

  setUp(() {
    service = _MockService();
    SharedPreferences.setMockInitialValues({'xb_consent_v1': true}); // 默认已同意，避免弹窗
  });

  Future<void> pump(
    WidgetTester t, {
    required bool ready,
    required bool firstLaunch,
    required bool offline,
    required AuthState auth,
  }) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          xboardServiceProvider.overrideWithValue(service),
          bootstrapReadyProvider.overrideWith(() => _FixedReady(ready)),
          firstLaunchProvider.overrideWith(() => _FixedFirst(firstLaunch)),
          isOfflineProvider.overrideWith((ref) => offline),
          authStateProvider.overrideWith(() => _FixedAuth(auth)),
        ],
        child: const MaterialApp(home: XboardServiceHomePage()),
      ),
    );
    await t.pump();
  }

  testWidgets('bootstrapReady=false → 配置加载异常', (t) async {
    await pump(t, ready: false, firstLaunch: false, offline: false, auth: AuthState.unauthenticated);
    expect(find.text('配置加载异常'), findsOneWidget);
  });

  testWidgets('首次安装 + 离线 → 首次离线提示页（登录/注册 disabled）', (t) async {
    await pump(t, ready: true, firstLaunch: true, offline: true, auth: AuthState.unauthenticated);
    expect(find.text('需要网络连接'), findsOneWidget);
    expect(find.text('检查网络'), findsOneWidget);
    // 登录/注册按钮 disabled
    final loginBtn = tester_findFilled(t, '登录');
    expect(loginBtn.onPressed, isNull);
  });

  testWidgets('在线 + 未登录 → 游客视图（登录/注册引导）', (t) async {
    await pump(t, ready: true, firstLaunch: false, offline: false, auth: AuthState.unauthenticated);
    expect(find.text('登录管理你的服务'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '注册新账号'), findsOneWidget);
  });

  testWidgets('已登录 → 账号卡（R6）+ 退出登录', (t) async {
    when(() => service.getSubscription()).thenAnswer((_) async =>
        XbResult.success(const XbDomainSubscription(
          email: 'a@b.com', uuid: 'uuid1234x', planName: 'Pro',
          totalBytes: 1000, usedBytes: 200,
        )));
    await pump(t, ready: true, firstLaunch: false, offline: false, auth: AuthState.authenticated);
    await t.pump(const Duration(milliseconds: 50));
    expect(find.byType(AccountInfoCard), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
  });

  testWidgets('离线 banner：offline=true 时显示', (t) async {
    await pump(t, ready: true, firstLaunch: false, offline: true, auth: AuthState.authenticated);
    when(() => service.getSubscription()).thenAnswer((_) async =>
        XbResult.success(const XbDomainSubscription(
          email: 'a@b.com', uuid: 'uuid1234x', totalBytes: 1, usedBytes: 0)));
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('当前离线，部分数据可能陈旧'), findsOneWidget);
  });
}

FilledButton tester_findFilled(WidgetTester t, String label) {
  return t.widgetList<FilledButton>(find.byType(FilledButton)).firstWhere(
        (b) => _hasText(b.child, label),
        orElse: () => throw StateError('no FilledButton with "$label"'),
      );
}

bool _hasText(Widget? w, String label) {
  if (w is Text) return w.data == label;
  return false;
}

/// 固定 authState 的测试 notifier。
class _FixedAuth extends AuthStateNotifier {
  _FixedAuth(this._fixed);
  final AuthState _fixed;
  @override
  AuthState build() => _fixed;
}

class _FixedReady extends BootstrapReady {
  _FixedReady(this._v);
  final bool _v;
  @override
  bool build() => _v;
}

class _FixedFirst extends FirstLaunch {
  _FixedFirst(this._v);
  final bool _v;
  @override
  bool build() => _v;
}
