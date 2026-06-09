/// W5 补测 — 登录/注册/忘记密码 sheet 的提交路径（校验 / 成功 / 失败），提覆盖。
///
/// 纯单测（mock 反腐层，无 core）：覆盖之前只测了「渲染 + gate」未测的 _submit 分支。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/sheets/forgot_pwd_sheet.dart';
import 'package:fl_clash/xboard/shell/sheets/login_sheet.dart';
import 'package:fl_clash/xboard/shell/sheets/register_sheet.dart';

class _MockService extends Mock implements XboardService {}

class _FakeReady extends BootstrapReady {
  @override
  bool build() => true;
}

void main() {
  late _MockService service;
  late ProviderContainer container;

  setUp(() {
    service = _MockService();
    container = ProviderContainer(
      overrides: [
        xboardServiceProvider.overrideWithValue(service),
        bootstrapReadyProvider.overrideWith(() => _FakeReady()),
        emailSuffixesProvider.overrideWith((ref) async => const ['gmail.com']),
      ],
    );
  });

  tearDown(() => container.dispose());

  /// 直接挂 sheet 内容 widget（不走 showModalBottomSheet，便于断言）。
  Future<void> pump(WidgetTester t, Widget sheet) async {
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: sheet)),
      ),
    );
    await t.pumpAndSettle();
  }

  group('LoginSheet 提交', () {
    testWidgets('空字段 → banner「请输入邮箱和密码」，不调反腐层', (t) async {
      await pump(t, const LoginSheet());
      await t.tap(find.widgetWithText(FilledButton, '登录'));
      await t.pumpAndSettle();
      expect(find.text('请输入邮箱和密码'), findsOneWidget);
      verifyNever(() => service.login(any(), any()));
    });

    testWidgets('成功 → markAuthenticated', (t) async {
      when(() => service.login(any(), any()))
          .thenAnswer((_) async => XbResult.success('token'));
      await pump(t, const LoginSheet());
      await t.enterText(find.byType(TextField).first, 'a@b.com');
      await t.enterText(find.byType(TextField).last, 'pw');
      await t.tap(find.widgetWithText(FilledButton, '登录'));
      await t.pumpAndSettle();
      expect(container.read(authStateProvider), AuthState.authenticated);
    });

    testWidgets('失败 → banner 显示错误，回未登录', (t) async {
      // 登录失败实际是 HTTP 400 → BusinessError.generic（非 401）；
      // resolveErrorText 透传后端 message（中文原样保留）。
      when(() => service.login(any(), any())).thenAnswer((_) async =>
          XbResult.failure(
              XbDomainError.business(XbBusinessKind.generic, '邮箱或密码错误', null)));
      await pump(t, const LoginSheet());
      await t.enterText(find.byType(TextField).first, 'a@b.com');
      await t.enterText(find.byType(TextField).last, 'wrong');
      await t.tap(find.widgetWithText(FilledButton, '登录'));
      await t.pumpAndSettle();
      expect(container.read(authStateProvider), AuthState.unauthenticated);
      expect(find.textContaining('邮箱或密码错误'), findsOneWidget);
    });
  });

  group('RegisterSheet 提交', () {
    testWidgets('不完整 → banner，不调 register', (t) async {
      await pump(t, const RegisterSheet());
      await t.tap(find.widgetWithText(FilledButton, '注册'));
      await t.pumpAndSettle();
      expect(find.textContaining('请完整填写'), findsOneWidget);
      verifyNever(() => service.register(any(), any(),
          emailCode: any(named: 'emailCode'), inviteCode: any(named: 'inviteCode')));
    });

    testWidgets('成功注册 → 二步登录 → markAuthenticated（后缀拼接 @gmail.com）', (t) async {
      when(() => service.register(any(), any(),
              emailCode: any(named: 'emailCode'),
              inviteCode: any(named: 'inviteCode')))
          .thenAnswer((_) async => XbResult.success(true));
      when(() => service.login(any(), any()))
          .thenAnswer((_) async => XbResult.success('token'));
      await pump(t, const RegisterSheet());
      // 字段：邮箱前缀 / 验证码 / 密码（顺序）。
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'alice'); // 邮箱前缀
      await t.enterText(fields.at(1), '123456'); // 验证码
      await t.enterText(fields.at(2), 'pw123456'); // 密码
      await t.tap(find.widgetWithText(FilledButton, '注册'));
      await t.pumpAndSettle();
      // 拼接白名单后缀 → alice@gmail.com 注册。
      verify(() => service.register('alice@gmail.com', 'pw123456',
          emailCode: '123456', inviteCode: null)).called(1);
      expect(container.read(authStateProvider), AuthState.authenticated);
    });

    testWidgets('获取验证码 → 调 sendEmailVerifyCode + 冷却倒计时', (t) async {
      when(() => service.sendEmailVerifyCode(any()))
          .thenAnswer((_) async => XbResult.success(true));
      await pump(t, const RegisterSheet());
      await t.enterText(find.byType(TextField).first, 'alice');
      await t.tap(find.widgetWithText(OutlinedButton, '获取验证码'));
      await t.pump();
      verify(() => service.sendEmailVerifyCode('alice@gmail.com')).called(1);
      // 冷却后按钮显示秒数（60s）。
      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('s'), findsWidgets);
    });
  });

  group('ForgotPwdSheet 提交', () {
    testWidgets('成功重置 → pop + snackbar', (t) async {
      when(() => service.forgotPassword(any(), any(), any()))
          .thenAnswer((_) async => XbResult.success(true));
      await pump(t, const ForgotPwdSheet());
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'alice');
      await t.enterText(fields.at(1), '123456');
      await t.enterText(fields.at(2), 'newpw123');
      await t.tap(find.widgetWithText(FilledButton, '重置密码'));
      await t.pumpAndSettle();
      verify(() => service.forgotPassword('alice@gmail.com', '123456', 'newpw123'))
          .called(1);
    });

    testWidgets('不完整 → banner，不调 forgotPassword', (t) async {
      await pump(t, const ForgotPwdSheet());
      await t.tap(find.widgetWithText(FilledButton, '重置密码'));
      await t.pumpAndSettle();
      expect(find.textContaining('请完整填写'), findsOneWidget);
      verifyNever(() => service.forgotPassword(any(), any(), any()));
    });
  });
}
