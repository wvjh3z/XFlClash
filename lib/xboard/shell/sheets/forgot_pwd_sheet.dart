/// 形态 A 忘记密码底部 sheet（spec `xboard-form-a-ui-revamp` / W5.3 / R5.9）。
///
/// 字段：邮箱账号(同款前缀 + 后缀下拉，复用 R5.6 白名单约束) → 验证码 → 新密码。
/// 认证 ◇ 复用形态 B 反腐层 `forgotPassword`（R5.10）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'auth_network_hint.dart';
import '../../providers/xboard_connectivity_provider.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/error_text.dart';
import 'package:fl_clash/xboard/widgets/xb_cooldown_guard.dart';
import 'package:fl_clash/xboard/widgets/xb_submit_guard.dart';

import '../../widgets/xb_ui_kit.dart' show XbGradientAction;
import 'login_sheet.dart' show showLoginSheet;
import 'sheet_scaffold.dart';
import '../../util/email_address.dart';

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

class _ForgotPwdSheetState extends ConsumerState<ForgotPwdSheet>
    with XbSubmitGuard<ForgotPwdSheet>, XbCooldownGuard<ForgotPwdSheet> {
  final _prefixCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  String? _suffix;
  bool _obscure = true;
  String? _banner;
  bool _offerProbe = false;

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
    if (_offline()) return;
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
      _offerProbe = error is XbNetwork || error is XbServer || error is XbUnconfirmed;
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
    if (_offline()) return;
    final email = _composeEmail(suffixes);
    final code = _codeCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (email == null) {
      setState(() => _banner = xbEmailValidationMessage(suffixes));
      return;
    }
    if (code.isEmpty || pw.isEmpty) {
      setState(() => _banner = '请完整填写邮箱、验证码和新密码');
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
          .forgotPassword(email, code, pw);
      if (!mounted) return;
      switch (result) {
        case XbSuccess(data: true):
          // 先抓根 messenger 引用再 pop（pop 后本 sheet context 失效，直接用会丢 toast）。
          final messenger = ScaffoldMessenger.of(context);
          Navigator.of(context).pop();
          messenger.showSnackBar(
            const SnackBar(content: Text('密码已重置，请用新密码登录')),
          );
        case XbSuccess():
          setState(() => _banner = '操作结果尚未确认，请先核对结果。如问题持续，请向客服反馈此问题。');
        case XbFailure(:final error):
          _offerProbe = error is XbNetwork || error is XbServer || error is XbUnconfirmed;
          setState(
            () => _banner = resolveErrorText(error, fallback: '重置失败，请重试'),
          );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(bootstrapReadyProvider);
    final suffixState = ref.watch(emailSuffixesProvider);
    final suffixes = suffixState.asData?.value ?? const <String>[];

    return XbSheetScaffold(
      title: '重置密码',
      subtitle: '通过注册邮箱验证身份并设置新密码',
      banner: _banner,
      footer: XbAuthLinks(prompt: '想起来了？', links: [
        ('返回登录', submitting ? null : () => switchXbAuthSheet(context, showLoginSheet)),
      ]),
      children: [
        if (_offerProbe && !submitting && _banner != null) const AuthNetworkHint(),
        XbEmailAccountField(
          prefixController: _prefixCtrl,
          suffixes: suffixes,
          selectedSuffix: _suffix,
          onSuffixChanged: (v) => setState(() => _suffix = v),
        ),
        if (suffixState.hasError || ref.watch(suffixLookupFailedProvider)) const XbEmailSuffixHint('邮箱后缀暂未加载，请输入完整邮箱；网络恢复后会重新获取。'),
        if (suffixes.isNotEmpty) const XbEmailSuffixHint('请选择注册时使用的邮箱后缀'),
        const SizedBox(height: 12),
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
            labelText: '设置新密码',
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: XbGradientAction(
            height: 50,
            onPressed: (!ready || submitting) ? null : () => _submit(suffixes),
            busyLabel: submitting ? '正在重置密码…' : null,
            child: Text(ready ? '重置密码' : '准备中…'),
          ),
        ),
      ],
    );
  }

  bool _offline() {
    if (!ref.read(interfaceUnavailableProvider)) return false;
    setState(() { _offerProbe = true; _banner = '未检测到网络连接，本次请求尚未发送。'; });
    return true;
  }
}
