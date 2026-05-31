/// W3.4.6 — R2 登录页 widget test：渲染 + loading + single-flight + 错误分流。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    hide AuthState;
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/pages/login_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/pending_destination_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  late _MockService service;

  setUp(() => service = _MockService());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [xboardServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: XboardLoginPage()),
      ),
    );
  }

  testWidgets('渲染：标题 + 邮箱/密码输入 + 登录按钮', (t) async {
    await pump(t);
    expect(find.text('欢迎回来'), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('立即注册'), findsOneWidget);
    expect(find.text('忘记密码？'), findsOneWidget);
  });

  testWidgets('空字段提交 → 字段红框校验，不调 service', (t) async {
    await pump(t);
    await t.tap(find.text('登录'));
    await t.pump();
    expect(find.text('请输入邮箱'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
    verifyNever(() => service.login(any(), any()));
  });

  testWidgets('成功登录 → authState=authenticated', (t) async {
    when(() => service.login(any(), any()))
        .thenAnswer((_) async => const XbSuccess('token'));
    final container = ProviderContainer(
      overrides: [xboardServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: XboardLoginPage()),
      ),
    );
    await t.enterText(find.byType(TextField).first, 'a@b.com');
    await t.enterText(find.byType(TextField).last, 'password');
    await t.tap(find.text('登录'));
    await t.pump(); // authenticating
    await t.pump(const Duration(milliseconds: 50)); // await login
    expect(container.read(authStateProvider), AuthState.authenticated);
  });

  testWidgets('rateLimit 错误 → 顶部 banner 倒计时文案', (t) async {
    when(() => service.login(any(), any())).thenAnswer((_) async =>
        const XbFailure(XbRateLimit(RateLimitKind.login, 5, 'too many')));
    await pump(t);
    await t.enterText(find.byType(TextField).first, 'a@b.com');
    await t.enterText(find.byType(TextField).last, 'wrong');
    await t.tap(find.text('登录'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('5 分钟后重试'), findsOneWidget);
    // 替换 widget 触发 dispose（取消倒计时 Timer，避免 pending timer 报错）
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('banned 错误 → banner 显示封禁文案', (t) async {
    when(() => service.login(any(), any())).thenAnswer((_) async =>
        const XbFailure(XbBusiness(BusinessErrorKind.banned, 'raw', null)));
    await pump(t);
    await t.enterText(find.byType(TextField).first, 'a@b.com');
    await t.enterText(find.byType(TextField).last, 'pw');
    await t.tap(find.text('登录'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('封禁'), findsOneWidget);
  });

  testWidgets('single-flight：登录中按钮变 spinner，无法再次点击', (t) async {
    var calls = 0;
    when(() => service.login(any(), any())).thenAnswer((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return const XbSuccess('token');
    });
    await pump(t);
    await t.enterText(find.byType(TextField).first, 'a@b.com');
    await t.enterText(find.byType(TextField).last, 'pw');
    await t.tap(find.text('登录'));
    await t.pump(); // 进入 authenticating + _inFlight=true → 按钮变 spinner

    // loading 态：'登录' 文本消失（按钮内是 spinner），证明无法再次点击
    expect(find.text('登录'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await t.pump(const Duration(milliseconds: 150)); // 等 login 完成
    expect(calls, 1); // 只调用 1 次
  });

  testWidgets('R12：登录成功 + pendingDestination → 跳目标页（buildXbRoute）', (t) async {
    when(() => service.login(any(), any()))
        .thenAnswer((_) async => const XbSuccess('token'));
    final container = ProviderContainer(
      overrides: [xboardServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    // 守卫预置：未登录点订单详情 → 记录 pending
    container.read(pendingDestinationProvider.notifier).set(
          const PendingDestination(XbRoute.orderDetail, {'tradeNo': 'T9'}),
        );
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: XboardLoginPage()),
      ),
    );
    await t.enterText(find.byType(TextField).first, 'a@b.com');
    await t.enterText(find.byType(TextField).last, 'password');
    await t.tap(find.text('登录'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    await t.pumpAndSettle();
    // 跳到目标页（占位页渲染 args）+ pending 已消费清空
    expect(find.textContaining('T9'), findsOneWidget);
    expect(container.read(pendingDestinationProvider), isNull);
  });
}
