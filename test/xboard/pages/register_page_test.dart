/// W3.3.7 — R1 注册页 widget test：渲染 + DD-9 二步登录 + 错误分流 + R1.7 loading。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' hide AuthState;
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/pages/register_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
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
        child: const MaterialApp(home: XboardRegisterPage()),
      ),
    );
  }

  /// 填全 5 字段（邀请码可选留空）。
  Future<void> fillValid(WidgetTester t) async {
    await t.enterText(find.widgetWithText(TextField, '邮箱'), 'a@b.com');
    await t.enterText(find.widgetWithText(TextField, '密码'), 'password');
    await t.enterText(find.widgetWithText(TextField, '确认密码'), 'password');
    await t.enterText(find.widgetWithText(TextField, '邮箱验证码'), '123456');
  }

  /// 滚动到注册按钮并点击（注册页字段多，按钮在 800x600 视口外，需先 ensureVisible）。
  Future<void> tapRegister(WidgetTester t) async {
    final btn = find.widgetWithText(FilledButton, '注册');
    await t.ensureVisible(btn);
    await t.pump();
    await t.tap(btn);
  }

  testWidgets('渲染：标题 + 5 字段 + 注册按钮', (t) async {
    await pump(t);
    expect(find.text('创建账号'), findsOneWidget);
    expect(find.widgetWithText(TextField, '邮箱'), findsOneWidget);
    expect(find.widgetWithText(TextField, '密码'), findsOneWidget);
    expect(find.widgetWithText(TextField, '确认密码'), findsOneWidget);
    expect(find.widgetWithText(TextField, '邮箱验证码'), findsOneWidget);
    expect(find.widgetWithText(TextField, '邀请码（可选）'), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '注册'), findsOneWidget);
  });

  testWidgets('空字段提交 → 红框校验，不调 register', (t) async {
    await pump(t);
    await tapRegister(t);
    await t.pump();
    expect(find.text('请输入邮箱'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
    expect(find.text('请输入验证码'), findsOneWidget);
    verifyNever(() => service.register(any(), any(),
        emailCode: any(named: 'emailCode'), inviteCode: any(named: 'inviteCode')));
  });

  testWidgets('两次密码不一致 → 红框', (t) async {
    await pump(t);
    await t.enterText(find.widgetWithText(TextField, '邮箱'), 'a@b.com');
    await t.enterText(find.widgetWithText(TextField, '密码'), 'password');
    await t.enterText(find.widgetWithText(TextField, '确认密码'), 'mismatch');
    await t.enterText(find.widgetWithText(TextField, '邮箱验证码'), '123456');
    await tapRegister(t);
    await t.pump();
    expect(find.text('两次密码不一致'), findsOneWidget);
  });

  testWidgets('注册成功 → DD-9 自动二步 login → authenticated', (t) async {
    when(() => service.register(any(), any(),
            emailCode: any(named: 'emailCode'),
            inviteCode: any(named: 'inviteCode')))
        .thenAnswer((_) async => const XbSuccess(true));
    when(() => service.login(any(), any()))
        .thenAnswer((_) async => const XbSuccess('token'));

    final container = ProviderContainer(
      overrides: [xboardServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: XboardRegisterPage()),
      ),
    );
    await fillValid(t);
    await tapRegister(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    verify(() => service.login(any(), any())).called(1); // DD-9 二步
    expect(container.read(authStateProvider), AuthState.authenticated);
  });

  testWidgets('emailAlreadyExists → banner 提示', (t) async {
    when(() => service.register(any(), any(),
            emailCode: any(named: 'emailCode'),
            inviteCode: any(named: 'inviteCode')))
        .thenAnswer((_) async => const XbFailure(
            XbBusiness(BusinessErrorKind.emailAlreadyExists, 'raw', null)));
    await pump(t);
    await fillValid(t);
    await tapRegister(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('邮箱已被使用'), findsOneWidget);
  });

  testWidgets('inviteCodeRequired → 邀请码红框', (t) async {
    when(() => service.register(any(), any(),
            emailCode: any(named: 'emailCode'),
            inviteCode: any(named: 'inviteCode')))
        .thenAnswer((_) async => const XbFailure(
            XbBusiness(BusinessErrorKind.inviteCodeRequired, 'raw', null)));
    await pump(t);
    await fillValid(t);
    await tapRegister(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('请填写邀请码'), findsOneWidget);
  });

  testWidgets('invalidEmailCode → 验证码红框', (t) async {
    when(() => service.register(any(), any(),
            emailCode: any(named: 'emailCode'),
            inviteCode: any(named: 'inviteCode')))
        .thenAnswer((_) async => const XbFailure(
            XbBusiness(BusinessErrorKind.invalidEmailCode, 'raw', null)));
    await pump(t);
    await fillValid(t);
    await tapRegister(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('验证码错误或已过期'), findsOneWidget);
  });

  testWidgets('generic（邮箱后缀白名单）→ 透传后端 message', (t) async {
    // 后端开启 email_whitelist 后非白名单邮箱注册返 400 generic + 中文 message（DD-10）。
    when(() => service.register(any(), any(),
            emailCode: any(named: 'emailCode'),
            inviteCode: any(named: 'inviteCode')))
        .thenAnswer((_) async => const XbFailure(
            XbBusiness(BusinessErrorKind.generic, '邮箱后缀不在白名单内', null)));
    await pump(t);
    await fillValid(t);
    await tapRegister(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('邮箱后缀不在白名单内'), findsOneWidget); // 透传，不被吞成通用文案
  });

  testWidgets('R1.7 loading：注册中按钮 spinner', (t) async {
    when(() => service.register(any(), any(),
            emailCode: any(named: 'emailCode'),
            inviteCode: any(named: 'inviteCode')))
        .thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return const XbSuccess(true);
    });
    when(() => service.login(any(), any()))
        .thenAnswer((_) async => const XbSuccess('token'));
    await pump(t);
    await fillValid(t);
    await tapRegister(t);
    await t.pump(); // authenticating
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.pump(const Duration(milliseconds: 150));
  });
}
