/// W4.3·W4.4·W4.5 — MineTab 单测（游客卡 / 账号卡用量 / 重置入口阈值 / 设置入口）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

XbDomainSubscription _sub({required int total, required int used}) =>
    XbDomainSubscription(
      email: 'demo@example.com',
      uuid: 'uid-123',
      planName: '专业版',
      totalBytes: total,
      usedBytes: used,
      expiredAt: DateTime(2026, 12, 31),
      planId: 1,
    );

Future<void> pumpMine(
  WidgetTester tester, {
  required AuthState auth,
  XbDomainSubscription? sub,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(() => _FakeAuth(auth)),
        if (sub != null)
          userProfileProvider.overrideWith((ref) async => sub),
      ],
      child: const MaterialApp(home: Scaffold(body: MineTab())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const gb = 1024 * 1024 * 1024;

  testWidgets('游客态 → 登录引导卡（R6.10）', (tester) async {
    await pumpMine(tester, auth: AuthState.unauthenticated);
    expect(find.text('登录后管理你的套餐与流量'), findsOneWidget);
    expect(find.text('登录 / 注册'), findsOneWidget);
    // 游客态设置区只有「设置」，无订单/退出。
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
  });

  testWidgets('已登录 → 账号卡显示邮箱(掩码)/套餐/用量%', (tester) async {
    await pumpMine(tester,
        auth: AuthState.authenticated,
        sub: _sub(total: 100 * gb, used: 37 * gb));
    expect(find.text('de***@example.com'), findsOneWidget);
    expect(find.text('专业版'), findsOneWidget);
    // 用量% 现并入标签文案（原型 .lab）。
    expect(find.text('本月已用流量（已使用 37%）'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
  });

  testWidgets('用量 <90% → 不显示流量重置入口（R6.3）', (tester) async {
    await pumpMine(tester,
        auth: AuthState.authenticated,
        sub: _sub(total: 100 * gb, used: 50 * gb));
    expect(find.text('流量重置'), findsNothing);
  });

  testWidgets('用量 ≥90% → 显示流量重置入口（R6.3）', (tester) async {
    await pumpMine(tester,
        auth: AuthState.authenticated,
        sub: _sub(total: 100 * gb, used: 95 * gb));
    expect(find.text('流量重置'), findsOneWidget);
  });

  testWidgets('已订阅 → 续费 + 购买/更改套餐双入口（R6.4-R6.6）', (tester) async {
    await pumpMine(tester,
        auth: AuthState.authenticated,
        sub: _sub(total: 100 * gb, used: 10 * gb));
    expect(find.text('续费当前套餐'), findsOneWidget);
    expect(find.text('购买 / 更改套餐'), findsOneWidget);
  });
}
