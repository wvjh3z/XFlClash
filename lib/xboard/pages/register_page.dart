/// R1 注册页（W3.3）—— M3 视觉样板 + DD-9 注册后二步 login（F407）。
///
/// 视觉：复用 XbBrandTheme / XbBrandBadge / XbTextField / XbPrimaryButton kit，与登录页同款布局。
///
/// 字段（v0.1 固定策略 DD-10）：邮箱 / 密码 / 确认密码 / 邮箱验证码（必填，带 60s 发送倒计时）/
/// 邀请码（可选，D4）。captcha 不渲染（D42 撤销）。
///
/// 行为：`sendEmailVerifyCode` 拿验证码（θ-5 合并文案 + 60s 倒计时）→ `register` →
/// success 后 **DD-9 自动二步 `login`** 拿鉴权 token（SDK register 不返 token，F407）。
/// 错误分流：emailAlreadyExists（θ-5 合并文案）/ inviteCodeRequired / invalidInviteCode → 邀请码红框。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show BusinessErrorKind;

import '../l10n/xboard_business_messages.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../providers/auth_state_provider.dart';
import '../providers/xboard_providers.dart';
import '../widgets/xb_ui_kit.dart';

/// 注册页。[brandColor] 由 flavor 注入（XboardConfig.brandColor），默认品牌红 D3。
class XboardRegisterPage extends ConsumerStatefulWidget {
  const XboardRegisterPage({super.key, this.brandColor = const Color(0xFFD92E1A)});

  final Color brandColor;

  @override
  ConsumerState<XboardRegisterPage> createState() => _XboardRegisterPageState();
}

class _XboardRegisterPageState extends ConsumerState<XboardRegisterPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _inviteCtrl = TextEditingController();

  bool _obscure = true;
  bool _inFlight = false; // ι-6 single-flight 锁
  String? _emailError;
  String? _passwordError;
  String? _confirmError;
  String? _codeError;
  String? _inviteError;
  String? _banner;
  int _codeCooldown = 0; // 发送验证码 60s 倒计时剩余秒
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    _codeCtrl.dispose();
    _inviteCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (_codeCooldown > 0) return;
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _emailError = '请先输入邮箱');
      return;
    }
    setState(() {
      _emailError = null;
      _banner = null;
    });
    final result = await ref.read(xboardServiceProvider).sendEmailVerifyCode(email);
    if (!mounted) return;
    switch (result) {
      case XbSuccess():
        // θ-5：合并文案，不区分邮箱是否已注册。
        setState(() => _banner = '如果该邮箱可用，验证码邮件已发送');
        _startCooldown(60);
      case XbFailure(:final error):
        if (error is XbBusiness &&
            error.kind == BusinessErrorKind.emailVerifyCodeRateLimit) {
          setState(() => _banner = '请稍后再试');
          _startCooldown(60);
        } else {
          _handleError(error);
        }
    }
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    setState(() => _codeCooldown = seconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _codeCooldown--);
      if (_codeCooldown <= 0) timer.cancel();
    });
  }

  Future<void> _submit() async {
    if (_inFlight) return;
    final email = _emailCtrl.text.trim();
    final pw = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;
    final code = _codeCtrl.text.trim();
    final invite = _inviteCtrl.text.trim();
    setState(() {
      _emailError = email.isEmpty ? '请输入邮箱' : null;
      _passwordError = pw.isEmpty ? '请输入密码' : null;
      _confirmError = confirm != pw ? '两次密码不一致' : null;
      _codeError = code.isEmpty ? '请输入验证码' : null;
      _inviteError = null;
      _banner = null;
    });
    if (_emailError != null ||
        _passwordError != null ||
        _confirmError != null ||
        _codeError != null) {
      return;
    }

    _inFlight = true;
    ref.read(authStateProvider.notifier).startAuthenticating();

    final service = ref.read(xboardServiceProvider);
    final regResult = await service.register(
      email,
      pw,
      emailCode: code,
      inviteCode: invite.isEmpty ? null : invite,
    );

    if (!mounted) {
      _inFlight = false;
      return;
    }

    switch (regResult) {
      case XbSuccess():
        // DD-9：register 不返 token（F407），成功后自动二步 login 拿鉴权 token。
        final loginResult = await service.login(email, pw);
        if (!mounted) {
          _inFlight = false;
          return;
        }
        _inFlight = false;
        switch (loginResult) {
          case XbSuccess():
            ref.read(authStateProvider.notifier).markAuthenticated();
            if (mounted) Navigator.of(context).maybePop();
          case XbFailure(:final error):
            // 注册成功但二步登录失败 → 引导用户去登录页。
            ref.read(authStateProvider.notifier).markUnauthenticated();
            setState(() => _banner = '注册成功，请前往登录');
            _handleError(error, silentBanner: true);
        }
      case XbFailure(:final error):
        _inFlight = false;
        ref.read(authStateProvider.notifier).markUnauthenticated();
        _handleError(error);
    }
  }

  void _handleError(XbDomainError error, {bool silentBanner = false}) {
    setState(() {
      switch (error) {
        case XbRateLimit(:final retryAfterMinutes):
          final mins = retryAfterMinutes ?? 60;
          _banner = '注册过于频繁，请 $mins 分钟后重试';
        case XbBusiness(:final kind):
          switch (kind) {
            case BusinessErrorKind.emailAlreadyExists:
              _banner = '邮箱已被使用，请直接登录';
            case BusinessErrorKind.inviteCodeRequired:
              _inviteError = '请填写邀请码';
            case BusinessErrorKind.invalidInviteCode:
              _inviteError = '邀请码无效';
            case BusinessErrorKind.invalidEmailCode:
              _codeError = '验证码错误或已过期';
            case BusinessErrorKind.generic:
              // 后端未识别子类型（含「邮箱后缀白名单」「reCAPTCHA 校验失败」等 v0.1 未建模
              // 的注册限制，DD-10）→ 优先透传后端 message（通常已是中文且最精准），
              // 仅当后端 message 为空才回退通用文案。
              if (!silentBanner) {
                _banner = error.message.isNotEmpty
                    ? error.message
                    : '注册失败，请稍后重试';
              }
            default:
              if (!silentBanner) {
                _banner = localizedBusinessMessage(kind, XbLocale.zhCN);
              }
          }
        case XbNetwork():
          if (!silentBanner) _banner = '网络异常，请检查网络后重试';
        case XbServer():
          if (!silentBanner) _banner = '服务异常，请稍后重试';
        default:
          if (!silentBanner) {
            _banner = error.message.isNotEmpty ? error.message : '注册失败，请稍后重试';
          }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final loading = authState == AuthState.authenticating;

    return XbBrandTheme(
      brandColor: widget.brandColor,
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Scaffold(
            backgroundColor: scheme.surface,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: const BackButton(),
            ),
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 8),
                        const Center(child: XbBrandBadge(icon: Icons.person_add_alt_1_rounded)),
                        const SizedBox(height: 20),
                        Text(
                          '创建账号',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '注册后即可订阅套餐、管理服务',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 24),
                        if (_banner != null) _buildBanner(scheme),
                        XbTextField(
                          label: '邮箱',
                          controller: _emailCtrl,
                          errorText: _emailError,
                          prefixIcon: Icons.mail_outline_rounded,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          enabled: !loading,
                          autofillHints: const [AutofillHints.email],
                        ),
                        const SizedBox(height: 16),
                        XbTextField(
                          label: '密码',
                          controller: _passwordCtrl,
                          errorText: _passwordError,
                          prefixIcon: Icons.lock_outline_rounded,
                          obscureText: _obscure,
                          textInputAction: TextInputAction.next,
                          enabled: !loading,
                          autofillHints: const [AutofillHints.newPassword],
                          suffix: IconButton(
                            icon: Icon(_obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        const SizedBox(height: 16),
                        XbTextField(
                          label: '确认密码',
                          controller: _confirmCtrl,
                          errorText: _confirmError,
                          prefixIcon: Icons.lock_outline_rounded,
                          obscureText: _obscure,
                          textInputAction: TextInputAction.next,
                          enabled: !loading,
                        ),
                        const SizedBox(height: 16),
                        _buildCodeRow(loading),
                        const SizedBox(height: 16),
                        XbTextField(
                          label: '邀请码（可选）',
                          controller: _inviteCtrl,
                          errorText: _inviteError,
                          prefixIcon: Icons.card_giftcard_rounded,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          enabled: !loading,
                        ),
                        const SizedBox(height: 24),
                        XbPrimaryButton(
                          label: '注册',
                          loading: loading,
                          onPressed: loading ? null : _submit,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('已有账号？',
                                style: TextStyle(color: scheme.onSurfaceVariant)),
                            TextButton(
                              onPressed: loading ? null : () => Navigator.of(context).maybePop(),
                              child: const Text('返回登录'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCodeRow(bool loading) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: XbTextField(
            label: '邮箱验证码',
            controller: _codeCtrl,
            errorText: _codeError,
            prefixIcon: Icons.verified_outlined,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            enabled: !loading,
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          height: 56,
          child: OutlinedButton(
            onPressed: (loading || _codeCooldown > 0) ? null : _sendCode,
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(_codeCooldown > 0 ? '${_codeCooldown}s' : '发送验证码'),
          ),
        ),
      ],
    );
  }

  Widget _buildBanner(ColorScheme scheme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _banner!,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
