/// 形态 A 登录底部 sheet（spec `xboard-form-a-ui-revamp` / W5.1 / R5.1·R5.2·R5.3·R5.10）。
///
/// **渐进登录（R5.3）**：底部 sheet（不全屏拦截），游客可先浏览各页面再按需登录。
/// **gate（R5.2）**：`bootstrapReadyProvider` 未就绪时按钮禁用 +「准备中」（避免未就绪调反腐层抛 StateError）。
/// **复用形态 B（R5.10，◇）**：认证调 `xboardServiceProvider.login` + `authStateProvider` 编排
/// + token 存储，全链路零重写（自有代码不经 adapter）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/error_text.dart';

import 'forgot_pwd_sheet.dart';
import 'register_sheet.dart';
import 'sheet_scaffold.dart';

/// 弹出登录 sheet。
Future<void> showLoginSheet(BuildContext context) {
  return showXbBottomSheet(
    context: context,
    builder: (_) => const LoginSheet(),
  );
}

/// 登录 sheet。
class LoginSheet extends ConsumerStatefulWidget {
  const LoginSheet({super.key});

  @override
  ConsumerState<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends ConsumerState<LoginSheet> {
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _obscure = true;
  bool _inFlight = false;
  String? _banner;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_inFlight) return;
    final email = _emailCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (email.isEmpty || pw.isEmpty) {
      setState(() => _banner = '请输入邮箱和密码');
      return;
    }
    setState(() {
      _inFlight = true;
      _banner = null;
    });
    ref.read(authStateProvider.notifier).startAuthenticating();
    final result = await ref.read(xboardServiceProvider).login(email, pw);
    if (!mounted) return;
    setState(() => _inFlight = false);
    switch (result) {
      case XbSuccess():
        ref.read(authStateProvider.notifier).markAuthenticated();
        Navigator.of(context).pop();
      case XbFailure(:final error):
        ref.read(authStateProvider.notifier).markUnauthenticated();
        setState(() => _banner = resolveErrorText(error, fallback: '登录失败，请重试'));
    }
  }

  @override
  Widget build(BuildContext context) {
    // R5.2 gate：bootstrap 未就绪 → 登录禁用。
    final ready = ref.watch(bootstrapReadyProvider);

    return XbSheetScaffold(
      title: '登录 MyClient',
      subtitle: '登录后同步你的专属节点',
      badge: const XbSheetBadge(letter: 'M'),
      banner: _banner,
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              showRegisterSheet(context);
            },
            child: const Text('注册账号'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              showForgotPwdSheet(context);
            },
            child: const Text('忘记密码？'),
          ),
        ],
      ),
      children: [
        TextField(
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            labelText: '邮箱账号',
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
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
            onPressed: (!ready || _inFlight) ? null : _submit,
            child: _inFlight
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(ready ? '登录' : '准备中…'),
          ),
        ),
      ],
    );
  }
}
