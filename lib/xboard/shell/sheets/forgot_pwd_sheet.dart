/// 形态 A 忘记密码底部 sheet（spec `xboard-form-a-ui-revamp` / W5.3 / R5.9）。
///
/// 字段：邮箱账号(同款前缀 + 后缀下拉，复用 R5.6 白名单约束) → 验证码 → 新密码。
/// 认证 ◇ 复用形态 B 反腐层 `forgotPassword`（R5.10）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';

import 'sheet_scaffold.dart';

/// 弹出忘记密码 sheet。
Future<void> showForgotPwdSheet(BuildContext context) {
  return showXbBottomSheet(
    context: context,
    builder: (_) => const ForgotPwdSheet(),
  );
}

/// 忘记密码 sheet。
class ForgotPwdSheet extends ConsumerStatefulWidget {
  const ForgotPwdSheet({super.key});

  @override
  ConsumerState<ForgotPwdSheet> createState() => _ForgotPwdSheetState();
}

class _ForgotPwdSheetState extends ConsumerState<ForgotPwdSheet> {
  final _prefixCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  String? _suffix;
  bool _obscure = true;
  bool _inFlight = false;
  String? _banner;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _prefixCtrl.dispose();
    _codeCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  String _composeEmail(List<String> suffixes) {
    final prefix = _prefixCtrl.text.trim();
    if (suffixes.isEmpty) return prefix;
    return '$prefix@${_suffix ?? suffixes.first}';
  }

  void _startCooldown() {
    setState(() => _cooldown = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _sendCode(List<String> suffixes) async {
    final email = _composeEmail(suffixes);
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _banner = '请先填写邮箱账号');
      return;
    }
    _startCooldown();
    final result = await ref.read(xboardServiceProvider).sendEmailVerifyCode(email);
    if (!mounted) return;
    if (result is XbFailure) {
      setState(() => _banner = (result as XbFailure).error.toString());
    }
  }

  Future<void> _submit(List<String> suffixes) async {
    if (_inFlight) return;
    final email = _composeEmail(suffixes);
    final code = _codeCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (email.isEmpty || !email.contains('@') || code.isEmpty || pw.isEmpty) {
      setState(() => _banner = '请完整填写邮箱、验证码和新密码');
      return;
    }
    setState(() {
      _inFlight = true;
      _banner = null;
    });
    final result =
        await ref.read(xboardServiceProvider).forgotPassword(email, code, pw);
    if (!mounted) return;
    setState(() => _inFlight = false);
    switch (result) {
      case XbSuccess():
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('密码已重置，请用新密码登录')),
        );
      case XbFailure(:final error):
        setState(() => _banner = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(bootstrapReadyProvider);
    final suffixes =
        ref.watch(emailSuffixesProvider).asData?.value ?? const <String>[];

    return XbSheetScaffold(
      title: '找回密码',
      banner: _banner,
      children: [
        XbEmailAccountField(
          prefixController: _prefixCtrl,
          suffixes: suffixes,
          selectedSuffix: _suffix,
          onSuffixChanged: (v) => setState(() => _suffix = v),
        ),
        const SizedBox(height: 12),
        XbVerifyCodeField(
          controller: _codeCtrl,
          cooldownSeconds: _cooldown,
          onSend: () => _sendCode(suffixes),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: '新密码',
            prefixIcon: const Icon(Icons.lock_reset),
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
            onPressed: (!ready || _inFlight) ? null : () => _submit(suffixes),
            child: _inFlight
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(ready ? '重置密码' : '准备中…'),
          ),
        ),
      ],
    );
  }
}
