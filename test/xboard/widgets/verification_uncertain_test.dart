import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/shell/sheets/register_sheet.dart';
import 'package:fl_clash/xboard/shell/sheets/forgot_pwd_sheet.dart';

class _Service extends Mock implements XboardService {}

class _Ready extends BootstrapReady {
  @override
  bool build() => true;
}

void main() {
  for (final forgot in [false, true]) {
    for (final scenario in ['business', 'unknown', 'rate', 'legacyFalse']) {
      final uncertain = scenario != 'business';
      testWidgets('verify mail forgot=$forgot scenario=$scenario cooldown', (
        tester,
      ) async {
        final service = _Service();
        var calls = 0;
        when(() => service.sendEmailVerifyCode(any())).thenAnswer((_) async {
          calls++;
          if (scenario == 'legacyFalse') return const XbSuccess(false);
          if (scenario == 'rate') {
            return const XbFailure(
              XbBusiness(
                XbBusinessKind.emailVerifyCodeRateLimit,
                '验证码已发送',
                null,
              ),
            );
          }
          return XbFailure(
            uncertain
                ? const XbUnconfirmed('sendEmailVerifyCode', '请检查邮箱')
                : const XbBusiness(XbBusinessKind.generic, '邮箱格式错误', null),
          );
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              xboardServiceProvider.overrideWithValue(service),
              emailSuffixesProvider.overrideWith((ref) async => []),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: forgot ? const ForgotPwdSheet() : const RegisterSheet(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).first,
          'fixture@example.test',
        );
        await tester.tap(find.text('获取验证码'));
        await tester.pump();
        expect(calls, 1);
        if (uncertain) {
          expect(find.text('60s'), findsOneWidget);
          await tester.pump(const Duration(seconds: 60));
        }
        expect(find.text('获取验证码'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  for (final forgot in [false, true]) {
    testWidgets(
      'legacy false never reports auth write success: forgot=$forgot',
      (tester) async {
        final service = _Service();
        when(
          () => service.register(
            any(),
            any(),
            emailCode: any(named: 'emailCode'),
          ),
        ).thenAnswer((_) async => const XbSuccess(false));
        when(
          () => service.forgotPassword(any(), any(), any()),
        ).thenAnswer((_) async => const XbSuccess(false));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              xboardServiceProvider.overrideWithValue(service),
              bootstrapReadyProvider.overrideWith(_Ready.new),
              emailSuffixesProvider.overrideWith((ref) async => []),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: forgot ? const ForgotPwdSheet() : const RegisterSheet(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).at(0),
          'fixture@example.test',
        );
        await tester.enterText(find.byType(TextField).at(1), '123456');
        await tester.enterText(
          find.byType(TextField).at(2),
          'password-fixture',
        );
        await tester.tap(
          find.widgetWithText(FilledButton, forgot ? '重置密码' : '注册'),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('操作结果尚未确认'), findsOneWidget);
        expect(find.textContaining('密码已重置'), findsNothing);
        verifyNever(() => service.login(any(), any()));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
