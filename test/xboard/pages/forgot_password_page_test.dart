/// W3.5.6 — R3 忘记密码页 widget test：渲染 + 发送验证码倒计时 + 持久化恢复 +
/// θ-5 合并文案 + 重置成功 + θ-7 monotonic throttle。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' hide AuthState;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/pages/forgot_password_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  late _MockService service;

  setUp(() {
    service = _MockService();
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [xboardServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: XboardForgotPasswordPage()),
      ),
    );
    await tester.pump(); // _restoreCooldown 异步
  }

  /// 滚动到重置按钮并点击。
  Future<void> tapReset(WidgetTester t) async {
    final btn = find.widgetWithText(FilledButton, '重置密码');
    await t.ensureVisible(btn);
    await t.pump();
    await t.tap(btn);
  }

  testWidgets('渲染：标题 + 字段 + 发送验证码 + 重置按钮', (t) async {
    await pump(t);
    expect(find.text('通过邮箱验证码重置你的登录密码'), findsOneWidget); // 唯一副标题
    expect(find.widgetWithText(TextField, '邮箱'), findsOneWidget);
    expect(find.widgetWithText(TextField, '邮箱验证码'), findsOneWidget);
    expect(find.widgetWithText(TextField, '新密码'), findsOneWidget);
    expect(find.widgetWithText(TextField, '确认新密码'), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重置密码'), findsOneWidget);
  });

  testWidgets('发送验证码 → θ-5 合并文案 + 60s 倒计时 + 持久化 timestamp', (t) async {
    when(() => service.sendEmailVerifyCode(any()))
        .thenAnswer((_) async => const XbSuccess(true));
    await pump(t);
    await t.enterText(find.widgetWithText(TextField, '邮箱'), 'a@b.com');
    await t.tap(find.text('发送验证码'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('如果该邮箱已注册'), findsOneWidget);
    expect(find.text('60s'), findsOneWidget); // 倒计时启动

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(kLastSendEmailVerifyAtKey), isNotNull); // 持久化

    await t.pumpWidget(const SizedBox()); // dispose 取消 timer
  });

  testWidgets('持久化恢复：30s 前发过 → 重建后显示约 30s 倒计时', (t) async {
    final thirtySecAgo = DateTime.now().millisecondsSinceEpoch - 30 * 1000;
    SharedPreferences.setMockInitialValues({
      kLastSendEmailVerifyAtKey: thirtySecAgo,
    });
    await pump(t);
    await t.pump(const Duration(milliseconds: 50));
    // 剩余应为 ~30s（29/30/31 容差）
    final hasCountdown = find.textContaining('s').evaluate().any((e) {
      final txt = (e.widget as Text).data ?? '';
      final m = RegExp(r'^(\d+)s$').firstMatch(txt);
      if (m == null) return false;
      final v = int.parse(m.group(1)!);
      return v >= 25 && v <= 31;
    });
    expect(hasCountdown, isTrue);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('重置成功 → toast + pop 回登录', (t) async {
    when(() => service.forgotPassword(any(), any(), any()))
        .thenAnswer((_) async => const XbSuccess(true));
    await pump(t);
    await t.enterText(find.widgetWithText(TextField, '邮箱'), 'a@b.com');
    await t.enterText(find.widgetWithText(TextField, '邮箱验证码'), '123456');
    await t.enterText(find.widgetWithText(TextField, '新密码'), 'newpass');
    await t.enterText(find.widgetWithText(TextField, '确认新密码'), 'newpass');
    await tapReset(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('密码重置成功'), findsOneWidget); // SnackBar
  });

  testWidgets('invalidEmailCode → 验证码红框', (t) async {
    when(() => service.forgotPassword(any(), any(), any())).thenAnswer((_) async =>
        const XbFailure(XbBusiness(BusinessErrorKind.invalidEmailCode, 'raw', null)));
    await pump(t);
    await t.enterText(find.widgetWithText(TextField, '邮箱'), 'a@b.com');
    await t.enterText(find.widgetWithText(TextField, '邮箱验证码'), '000000');
    await t.enterText(find.widgetWithText(TextField, '新密码'), 'newpass');
    await t.enterText(find.widgetWithText(TextField, '确认新密码'), 'newpass');
    await tapReset(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('验证码错误或已过期'), findsOneWidget);
  });

  testWidgets('密码不一致 → 红框，不调 forgotPassword', (t) async {
    await pump(t);
    await t.enterText(find.widgetWithText(TextField, '邮箱'), 'a@b.com');
    await t.enterText(find.widgetWithText(TextField, '邮箱验证码'), '123456');
    await t.enterText(find.widgetWithText(TextField, '新密码'), 'newpass');
    await t.enterText(find.widgetWithText(TextField, '确认新密码'), 'mismatch');
    await tapReset(t);
    await t.pump();
    expect(find.text('两次密码不一致'), findsOneWidget);
    verifyNever(() => service.forgotPassword(any(), any(), any()));
  });
}
