/// 形态 A 注册底部 sheet（spec `xboard-form-a-ui-revamp` / W5.2 / R5.5·R5.6·R5.7·R5.8）。
///
/// 字段顺序（R5.5/R5.7）：邮箱账号(前缀 2/3 + 后缀下拉 1/3) → 验证码 → 密码。
/// 后缀来自 `emailSuffixesProvider`（W0.2 白名单）；白名单外不可注册（R5.6）。
/// 验证码短框 + 获取按钮 + 冷却倒计时（R5.8）。认证 ◇ 复用形态 B 反腐层（R5.10）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/error_text.dart';
import 'package:fl_clash/xboard/widgets/xb_cooldown_guard.dart';
import 'package:fl_clash/xboard/widgets/xb_submit_guard.dart';

import 'sheet_scaffold.dart';
import '../../util/email_address.dart';

/// 弹出注册 sheet。
Future<void> showRegisterSheet(BuildContext context) {
  return showXbBottomSheet(
    context: context,
    builder: (_) => const RegisterSheet(),
  );
}

/// 注册 sheet。
class RegisterSheet extends ConsumerStatefulWidget {
  const RegisterSheet({super.key});

  @override
  ConsumerState<RegisterSheet> createState() => _RegisterSheetState();
}

class _RegisterSheetState extends ConsumerState<RegisterSheet>
    with XbSubmitGuard<RegisterSheet>, XbCooldownGuard<RegisterSheet> {
  final _prefixCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  String? _suffix;
  bool _obscure = true;
  String? _banner;

  @override
  void dispose() {
    _prefixCtrl.dispose();
    _codeCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  String? _composeEmail(List<String> suffixes) =>
      xbComposeEmail(_prefixCtrl.text, suffixes, _suffix);

  Future<void> _sendCode(List<String> suffixes) async {
    if (cooling) return;
    final email = _composeEmail(suffixes);
    if (email == null) {
      setState(() => _banner = xbEmailValidationMessage(suffixes));
      return;
    }
    startCooldown();
    final result = await ref
        .read(xboardServiceProvider)
        .sendEmailVerifyCode(email);
    if (!mounted) return;
    final error = switch (result) {
      XbSuccess(data: true) => null,
      XbFailure(:final error) => error,
      _ => const XbUnconfirmed(
        'sendEmailVerifyCode',
        '验证码发送结果尚未确认，请先检查邮箱。如问题持续，请向客服反馈此问题。',
      ),
    };
    if (error != null) {
      // A lost response may still have delivered mail; preserve the cooldown.
      if (error is! XbUnconfirmed &&
          error is! XbRateLimit &&
          !(error is XbBusiness &&
              error.kind == XbBusinessKind.emailVerifyCodeRateLimit)) {
        resetCooldown();
      }
      setState(() => _banner = resolveErrorText(error, fallback: '发送失败，请重试'));
    }
  }

  Future<void> _submit(List<String> suffixes) async {
    final email = _composeEmail(suffixes);
    final code = _codeCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (email == null) {
      setState(() => _banner = xbEmailValidationMessage(suffixes));
      return;
    }
    if (code.isEmpty || pw.isEmpty) {
      setState(() => _banner = '请完整填写邮箱、验证码和密码');
      return;
    }
    if (pw.length < 8) {
      setState(() => _banner = '密码至少需要 8 位');
      return;
    }
    setState(() => _banner = null);
    await runSubmit(() async {
      final auth = ref.read(authStateProvider.notifier);
      final attempt = auth.startAuthenticating();
      await auth.waitForSessionCleanup();
      if (!mounted || !auth.isAuthenticationCurrent(attempt)) return;
      final result = await ref
          .read(xboardServiceProvider)
          .register(email, pw, emailCode: code);
      if (!mounted || !auth.isAuthenticationCurrent(attempt)) return;
      switch (result) {
        case XbSuccess(data: true):
          // 注册成功 → 二步登录（form B DD-9 同款：register 不返 token）。
          final login = await ref.read(xboardServiceProvider).login(email, pw);
          if (!mounted) return;
          if (login is XbSuccess<String>) {
            final established = await auth.completeAuthentication(
              token: login.data,
              attempt: attempt,
            );
            if (!mounted) return;
            if (established) {
              Navigator.of(context).pop();
            } else if (auth.isAuthenticationCurrent(attempt)) {
              auth.failAuthentication(attempt);
              setState(() => _banner = '注册成功，请手动登录');
            }
          } else if (auth.isAuthenticationCurrent(attempt)) {
            auth.failAuthentication(attempt);
            setState(() => _banner = '注册成功，请手动登录');
          }
        case XbSuccess():
          auth.failAuthentication(attempt);
          setState(() => _banner = '操作结果尚未确认，请先核对结果。如问题持续，请向客服反馈此问题。');
        case XbFailure(:final error):
          if (!auth.isAuthenticationCurrent(attempt)) return;
          auth.failAuthentication(attempt);
          setState(
            () => _banner = resolveErrorText(error, fallback: '注册失败，请重试'),
          );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(bootstrapReadyProvider);
    // 白名单后缀（fail-open：失败/加载中 → 空 = 任意后缀，不阻塞）。
    final suffixes =
        ref.watch(emailSuffixesProvider).asData?.value ?? const <String>[];

    return XbSheetScaffold(
      title: '注册',
      banner: _banner,
      children: [
        // 邮箱账号（前缀 + 后缀下拉，R5.5/R5.6/R5.7）。
        XbEmailAccountField(
          prefixController: _prefixCtrl,
          suffixes: suffixes,
          selectedSuffix: _suffix,
          onSuffixChanged: (v) => setState(() => _suffix = v),
        ),
        const SizedBox(height: 12),
        // 验证码在密码上方（R5.7），短框 + 获取按钮（R5.8）。
        XbVerifyCodeField(
          controller: _codeCtrl,
          cooldownSeconds: cooldownSeconds,
          onSend: () => _sendCode(suffixes),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: '密码',
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: (!ready || submitting) ? null : () => _submit(suffixes),
            child: submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(ready ? '注册' : '准备中…'),
          ),
        ),
      ],
    );
  }
}
