/// 形态 A 注册底部 sheet（spec `xboard-form-a-ui-revamp` / W5.2 / R5.5·R5.6·R5.7·R5.8）。
///
/// 字段顺序（R5.5/R5.7）：邮箱账号(前缀 2/3 + 后缀下拉 1/3) → 验证码 → 密码。
/// 后缀来自 `emailSuffixesProvider`（W0.2 白名单）；白名单外不可注册（R5.6）。
/// 验证码短框 + 获取按钮 + 冷却倒计时（R5.8）。认证 ◇ 复用形态 B 反腐层（R5.10）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'auth_network_hint.dart';
import '../../providers/xboard_connectivity_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/error_text.dart';
import 'package:fl_clash/xboard/widgets/xb_cooldown_guard.dart';
import 'package:fl_clash/xboard/widgets/xb_submit_guard.dart';

import '../../config/xboard_config.dart';
import '../../widgets/xb_ui_kit.dart' show XbGradientAction;
import 'login_sheet.dart' show showLoginSheet;
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
      setState(() => _banner = '请完整填写邮箱、验证码和密码');
      return;
    }
    if (pw.length < 8) {
      setState(() => _banner = '密码至少需要 8 位');
      return;
    }
    setState(() => _banner = null);
    final route = ModalRoute.of(context);
    await runSubmit(() async {
      final auth = ref.read(authStateProvider.notifier);
      final attempt = auth.startAuthenticating();
      await auth.waitForSessionCleanup();
      if (!mounted || route?.isCurrent != true || route?.isActive != true) {
        auth.failAuthentication(attempt);
        return;
      }
      if (!auth.isAuthenticationCurrent(attempt)) return;
      final result = await ref
          .read(xboardServiceProvider)
          .register(email, pw, emailCode: code);
      if (!mounted || route?.isCurrent != true || route?.isActive != true) {
        auth.failAuthentication(attempt);
        return;
      }
      if (!auth.isAuthenticationCurrent(attempt)) return;
      switch (result) {
        case XbSuccess(data: true):
          // 注册成功 → 二步登录（form B DD-9 同款：register 不返 token）。
          final service = ref.read(xboardServiceProvider);
          final scoped = service is XboardAuthenticationRequestControl
              ? service as XboardAuthenticationRequestControl : null;
          final login = scoped != null
              ? await scoped.loginForRequest(email, pw,
                  isActive: () => auth.isAuthenticationCurrent(attempt),
                  establish: (token) => auth.completeAuthentication(token: token, attempt: attempt))
              : await service.login(email, pw);
          // Once login has saved credentials, its session completion outlives
          // this sheet. Only UI feedback/navigation requires mounted.
          if (login is XbSuccess<String>) {
            final established = scoped != null ? true : await auth.completeAuthentication(
              token: login.data,
              attempt: attempt,
            );
            if (established) {
              if (mounted && route?.isCurrent == true && route?.isActive == true) {
                route?.navigator?.pop();
              }
            } else {
              if (auth.isAuthenticationCurrent(attempt)) {
                auth.failAuthentication(attempt);
                if (mounted && route?.isCurrent == true) {
                  setState(() => _banner = '注册成功，请手动登录');
                }
              }
            }
          } else if (auth.isAuthenticationCurrent(attempt)) {
            auth.failAuthentication(attempt);
            if (mounted && route?.isCurrent == true) setState(() => _banner = '注册成功，请手动登录');
          }
        case XbSuccess():
          auth.failAuthentication(attempt);
          setState(() => _banner = '操作结果尚未确认，请先核对结果。如问题持续，请向客服反馈此问题。');
        case XbFailure(:final error):
          if (!auth.isAuthenticationCurrent(attempt)) return;
          _offerProbe = error is XbNetwork || error is XbServer || error is XbUnconfirmed;
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
    final suffixState = ref.watch(emailSuffixesProvider);
    final suffixes = suffixState.asData?.value ?? const <String>[];

    return XbSheetScaffold(
      title: '注册 ${XboardConfig.current.appName}',
      subtitle: '创建账号，开启加密保护',
      banner: _banner,
      footer: XbAuthLinks(prompt: '已有账号？', links: [
        ('返回登录', submitting ? null : () => switchXbAuthSheet(context, showLoginSheet)),
      ]),
      children: [
        if (_offerProbe && !submitting && _banner != null) const AuthNetworkHint(),
        // 邮箱账号（前缀 + 后缀下拉，R5.5/R5.6/R5.7）。
        XbEmailAccountField(
          prefixController: _prefixCtrl,
          suffixes: suffixes,
          selectedSuffix: _suffix,
          onSuffixChanged: (v) => setState(() => _suffix = v),
        ),
        if (suffixState.hasError || ref.watch(suffixLookupFailedProvider)) const XbEmailSuffixHint('邮箱后缀暂未加载，请输入完整邮箱；网络恢复后会重新获取。'),
        if (suffixes.isNotEmpty) const XbEmailSuffixHint('邮箱后缀由服务端提供，请从列表中选择'),
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
            labelText: '设置密码',
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
            busyLabel: submitting ? '正在注册…' : null,
            child: Text(ready ? '注册' : '准备中…'),
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
