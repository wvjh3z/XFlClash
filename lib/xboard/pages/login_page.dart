/// R2 登录页（W3.4）—— M3 精装视觉样板 + ι-6 single-flight 防连点。
///
/// 视觉：XbBrandTheme 品牌色叠加 + XbBrandBadge 头部徽标 + XbTextField/XbPrimaryButton kit；
/// 居中卡片布局，桌面端限宽 420，移动端铺满。a11y：textScaleFactor 跟随系统，字段 autofill。
///
/// 行为：authStateProvider 驱动 loading（authenticating → 按钮 spinner + 输入禁用）；
/// 错误分流（rateLimit 倒计时 / banned 强制登出 / business 精准文案 / 其余 toast）；
/// single-flight 锁防连点 5 次撞后端 60min 锁定（ι-6 / F170）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show BusinessErrorKind, RateLimitKind;

import '../l10n/xboard_business_messages.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../providers/auth_state_provider.dart';
import '../providers/pending_destination_provider.dart';
import '../providers/xboard_providers.dart';
import '../widgets/xb_ui_kit.dart';
import 'forgot_password_page.dart';
import 'register_page.dart';

/// 登录页。[brandColor] 由 flavor 注入（XboardConfig.brandColor），默认品牌红 D3。
class XboardLoginPage extends ConsumerStatefulWidget {
  const XboardLoginPage({super.key, this.brandColor = const Color(0xFFD92E1A)});

  final Color brandColor;

  @override
  ConsumerState<XboardLoginPage> createState() => _XboardLoginPageState();
}

class _XboardLoginPageState extends ConsumerState<XboardLoginPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _obscure = true;
  bool _inFlight = false; // ι-6 single-flight 锁
  String? _emailError;
  String? _passwordError;
  String? _banner; // 顶部错误/倒计时文案
  int _lockSeconds = 0; // rateLimit 倒计时剩余秒
  Timer? _countdownTimer;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_inFlight || _lockSeconds > 0) return; // single-flight + 限流期禁止
    final email = _emailCtrl.text.trim();
    final pw = _passwordCtrl.text;
    setState(() {
      _emailError = email.isEmpty ? '请输入邮箱' : null;
      _passwordError = pw.isEmpty ? '请输入密码' : null;
      _banner = null;
    });
    if (_emailError != null || _passwordError != null) return;

    _inFlight = true;
    ref.read(authStateProvider.notifier).startAuthenticating();

    final result = await ref.read(xboardServiceProvider).login(email, pw);

    if (!mounted) return;
    _inFlight = false;

    switch (result) {
      case XbSuccess():
        ref.read(authStateProvider.notifier).markAuthenticated();
        // R12：登录成功 → 有 pendingDestination 则跳目标页（替换登录页，保留来源栈），
        // 否则 pop 回来源（R13.2）。用纯函数 buildXbRoute + 当前 context 构造（Property 22）。
        final pending = ref.read(pendingDestinationProvider.notifier).consume();
        if (!mounted) return;
        final nav = Navigator.of(context);
        if (pending != null) {
          nav.pushReplacement(
            MaterialPageRoute<void>(
              builder: (ctx) => buildXbRoute(pending.route, pending.args, ctx),
            ),
          );
        } else {
          nav.maybePop();
        }
      case XbFailure(:final error):
        ref.read(authStateProvider.notifier).markUnauthenticated();
        _handleError(error);
    }
  }

  void _handleError(XbDomainError error) {
    setState(() {
      switch (error) {
        case XbRateLimit(:final kind, :final retryAfterMinutes):
          final mins = retryAfterMinutes ?? 5;
          _banner = kind == RateLimitKind.login
              ? '密码错误次数过多，请 $mins 分钟后重试'
              : '请求过于频繁，请 $mins 分钟后重试';
          _startCountdown(mins * 60);
        case XbBusiness(:final kind, :final message):
          // 后端密码错误走 HTTP 400 → BusinessError(generic)，不是 401；
          // 命中"邮箱或密码错误"类 message 时按凭据错误内联展示（与 XbUnauthorized 一致）。
          if (_looksLikeBadCredentials(message)) {
            _passwordError = '邮箱或密码错误';
          } else if (kind == BusinessErrorKind.generic ||
              kind == BusinessErrorKind.validationFailed) {
            // 未细分的业务错误：优先透传后端真实 message（比"操作失败"更有用）。
            _banner = message.isNotEmpty
                ? message
                : localizedBusinessMessage(kind, XbLocale.zhCN);
          } else {
            _banner = localizedBusinessMessage(kind, XbLocale.zhCN);
          }
        case XbUnauthorized():
          _passwordError = '邮箱或密码错误';
        case XbNetwork():
          _banner = '网络异常，请检查网络后重试';
        case XbServer():
          _banner = '服务异常，请稍后重试';
        default:
          _banner = error.message.isNotEmpty ? error.message : '登录失败，请稍后重试';
      }
    });
  }

  /// 后端凭据错误 message 判定（zh / en 双语；wrong-password 走 HTTP 400 business）。
  bool _looksLikeBadCredentials(String message) {
    final m = message.toLowerCase();
    return m.contains('邮箱或密码') ||
        m.contains('密码错误') ||
        m.contains('账号或密码') ||
        m.contains('用户名或密码') ||
        m.contains('incorrect') && m.contains('password') ||
        m.contains('invalid') && (m.contains('password') || m.contains('credential')) ||
        m.contains('wrong') && m.contains('password');
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    setState(() => _lockSeconds = seconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _lockSeconds--);
      if (_lockSeconds <= 0) timer.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final loading = authState == AuthState.authenticating;
    final cs = Theme.of(context).colorScheme;

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
                        const SizedBox(height: 12),
                        const Center(child: XbBrandBadge()),
                        const SizedBox(height: 24),
                        Text(
                          '欢迎回来',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '登录你的账号，管理订阅与套餐',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 28),
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
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          enabled: !loading,
                          autofillHints: const [AutofillHints.password],
                          suffix: IconButton(
                            icon: Icon(_obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: loading
                                ? null
                                : () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => XboardForgotPasswordPage(
                                            brandColor: widget.brandColor),
                                      ),
                                    ),
                            child: const Text('忘记密码？'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        XbPrimaryButton(
                          label: _lockSeconds > 0
                              ? '请等待 ${_lockSeconds}s'
                              : '登录',
                          loading: loading,
                          onPressed:
                              (loading || _lockSeconds > 0) ? null : _submit,
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('还没有账号？',
                                style: TextStyle(color: cs.onSurfaceVariant)),
                            TextButton(
                              onPressed: loading
                                  ? null
                                  : () => Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => XboardRegisterPage(
                                              brandColor: widget.brandColor),
                                        ),
                                      ),
                              child: const Text('立即注册'),
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
