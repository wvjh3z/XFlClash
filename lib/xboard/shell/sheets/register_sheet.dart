/// 形态 A 注册底部 sheet（spec `xboard-form-a-ui-revamp` / W5.2 / R5.5·R5.6·R5.7·R5.8）。
///
/// 字段顺序（R5.5/R5.7）：邮箱账号(前缀 2/3 + 后缀下拉 1/3) → 验证码 → 密码。
/// 后缀来自 `emailSuffixesProvider`（W0.2 白名单）；白名单外不可注册（R5.6）。
/// 验证码短框 + 获取按钮 + 冷却倒计时（R5.8）。认证 ◇ 复用形态 B 反腐层（R5.10）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/error_text.dart';
import 'package:fl_clash/xboard/widgets/xb_cooldown_guard.dart';
import 'package:fl_clash/xboard/widgets/xb_submit_guard.dart';

import 'sheet_scaffold.dart';

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

  String _composeEmail(List<String> suffixes) {
    final prefix = _prefixCtrl.text.trim();
    if (suffixes.isEmpty) return prefix; // 白名单禁用 → 用户自填完整邮箱
    final suffix = _suffix ?? suffixes.first;
    return '$prefix@$suffix';
  }

  Future<void> _sendCode(List<String> suffixes) async {
    final email = _composeEmail(suffixes);
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _banner = '请先填写邮箱账号');
      return;
    }
    startCooldown();
    final result = await ref.read(xboardServiceProvider).sendEmailVerifyCode(email);
    if (!mounted) return;
    if (result is XbFailure) {
      // 发送失败 → 重置冷却（让用户可立即重发，不被无谓锁 60s）。
      resetCooldown();
      setState(() =>
          _banner = resolveErrorText((result as XbFailure).error, fallback: '发送失败，请重试'));
    }
  }

  Future<void> _submit(List<String> suffixes) async {
    final email = _composeEmail(suffixes);
    final code = _codeCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (email.isEmpty || !email.contains('@') || code.isEmpty || pw.isEmpty) {
      setState(() => _banner = '请完整填写邮箱、验证码和密码');
      return;
    }
    if (pw.length < 8) {
      setState(() => _banner = '密码至少需要 8 位');
      return;
    }
    setState(() => _banner = null);
    await runSubmit(() async {
      final result = await ref
          .read(xboardServiceProvider)
          .register(email, pw, emailCode: code);
      if (!mounted) return;
      switch (result) {
        case XbSuccess():
          // 注册成功 → 二步登录（form B DD-9 同款：register 不返 token）。
          final login = await ref.read(xboardServiceProvider).login(email, pw);
          if (!mounted) return;
          if (login is XbSuccess) {
            ref.read(authStateProvider.notifier).markAuthenticated();
            Navigator.of(context).pop();
          } else {
            setState(() => _banner = '注册成功，请手动登录');
          }
        case XbFailure(:final error):
          setState(() => _banner = resolveErrorText(error, fallback: '注册失败，请重试'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(bootstrapReadyProvider);
    // 白名单后缀（fail-open：失败/加载中 → 空 = 任意后缀，不阻塞）。
    final suffixes = ref.watch(emailSuffixesProvider).asData?.value ?? const <String>[];

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
            prefixIcon: const Icon(Icons.lock_outline),
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
