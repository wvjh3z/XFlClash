/// W4.3·W4.4·W4.5 — MineTab 单测（游客卡 / 账号卡用量 / 重置入口阈值 / 设置入口）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbSkeletonBar;

class _MockService extends Mock implements XboardService {}

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
  // 注：账号卡加载骨架（XbSkeletonBar）含无限 shimmer 动画，pumpAndSettle 会永不收敛。
  // 用固定多次 pump 让 async provider 落地 + skeleton 被真实卡片替换。
  await tester.pump(); // 触发 provider future
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  const gb = 1024 * 1024 * 1024;

  testWidgets('游客态 → 登录引导卡（R6.10）', (tester) async {
    await pumpMine(tester, auth: AuthState.unauthenticated);
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('登录后同步专属节点与套餐'), findsOneWidget);
    expect(find.text('登录 / 注册'), findsOneWidget);
    // 游客态设置区只有「设置」，无订单/退出。
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
  });

  testWidgets('已登录 → 账号卡显示邮箱(掩码)/套餐/用量%', (tester) async {
    await pumpMine(tester,
        auth: AuthState.authenticated,
        sub: _sub(total: 100 * gb, used: 37 * gb));
    expect(find.text('demo@example.com'), findsOneWidget);
    expect(find.text('专业版'), findsOneWidget);
    // 紧凑卡：用量% 在流量行右侧「已用 N%」（去掉了原「本月已用流量（已使用 N%）」标签行）。
    expect(find.text('已用 37%'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    // 邮箱后有复制按钮（已登录账号卡）。
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
  });

  testWidgets('点复制按钮 → 邮箱写入剪贴板 + toast', (tester) async {
    // 拦截剪贴板平台调用并记录写入值。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpMine(tester,
        auth: AuthState.authenticated,
        sub: _sub(total: 100 * gb, used: 37 * gb));
    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();
    expect(copied, 'demo@example.com', reason: '点复制应把邮箱写入剪贴板');
    expect(find.text('已复制邮箱'), findsOneWidget, reason: 'toast 提示');
  });

  testWidgets('游客态 → 无复制按钮（无邮箱）', (tester) async {
    await pumpMine(tester, auth: AuthState.unauthenticated);
    expect(find.byIcon(Icons.content_copy), findsNothing);
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

  testWidgets('账号加载失败 → 点重新加载 → 黄横幅出现，重试落定后横幅消失（不卡死）',
      (tester) async {
    final svc = _MockService();
    // 重试调反腐层 getSubscription：延迟后返失败（XbResult 永不抛、必落定）→ 横幅应能正常撤除。
    when(svc.getSubscription).thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return XbResult.failure(const XbNetwork(XbNetworkKind.unknown, 'down'));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authStateProvider.overrideWith(() => _FakeAuth(AuthState.authenticated)),
          xboardServiceProvider.overrideWithValue(svc),
          userProfileProvider.overrideWith((ref) async => throw Exception('down')),
        ],
        child: const MaterialApp(home: Scaffold(body: MineTab())),
      ),
    );
    // keepAlive 首次错误经 AsyncLoading(error:)→AsyncError，pumpAndSettle 落定到失败卡。
    try {
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    } catch (_) {}
    expect(find.text('账号信息加载失败'), findsOneWidget);

    // 点重新加载 → 同步 setState(_retrying=true) → 黄横幅出现。
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    expect(find.text('正在刷新服务，请稍候…'), findsOneWidget);
    // 11d：重试态与首次加载同布局——卡片不丢（骨架卡占位 + 禁用按钮行），不只是一条横幅。
    expect(find.byType(XbSkeletonBar), findsWidgets,
        reason: '重试态保留骨架卡占位（卡片不丢，原型 11d）');
    expect(find.text('续费当前套餐'), findsOneWidget,
        reason: '重试态显示禁用的续费/购买按钮行');

    // 等 getSubscription 落定 + invalidate + setState(_retrying=false)。
    // _retry await 的是反腐层（必返回），故横幅一定撤除（验证不卡死）。
    try {
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    } catch (_) {}
    expect(find.text('正在刷新服务，请稍候…'), findsNothing,
        reason: '重试落定后横幅必须消失（不卡死）');
    expect(find.text('账号信息加载失败'), findsOneWidget, reason: '重试仍失败 → 回到失败卡');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
