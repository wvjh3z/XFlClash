/// R3 忘记密码页（W3.5）—— 验证码重置 + R3.2.bis 持久化倒计时 + θ-7 单调时钟 throttle。
///
/// 视觉：复用 XbBrandTheme / XbBrandBadge / XbTextField / XbPrimaryButton kit。
///
/// 字段：邮箱 / 验证码（带 60s 发送倒计时）/ 新密码 / 确认新密码。
///
/// 倒计时双时钟（θ-7 / R3.2.bis）：
/// - **持久化**：发送验证码后写 SharedPreferences `xb_last_send_email_verify_at_v1`（wall clock ms），
///   UI 重建 / 回前台从该 timestamp 算剩余秒，防倒计时重置（kill App 重启仍生效）。
/// - **throttle gate（安全）**：用 `Stopwatch`（monotonic）守门，防用户改系统时间绕过 60s 撞后端锁定。
///   即「显示用 wall clock，放行判定用 monotonic」。
///
/// 错误处理：θ-5 合并文案「如果该邮箱已注册，重置邮件已发送」（不区分邮箱存在与否，OWASP ASVS 5.1.1）。
/// 重置成功：toast「密码重置成功」+ 跳回登录页（R3.4）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show BusinessErrorKind;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../widgets/xb_ui_kit.dart';

/// R3.2.bis 持久化 key（DD-22 v1 段）。
const String kLastSendEmailVerifyAtKey = 'xb_last_send_email_verify_at_v1';

/// 验证码冷却秒（F359 后端 60s/email）。
const int kEmailVerifyCooldownSeconds = 60;

/// 忘记密码页。[brandColor] 由 flavor 注入，默认品牌红 D3。
class XboardForgotPasswordPage extends ConsumerStatefulWidget {
  const XboardForgotPasswordPage({super.key, this.brandColor = const Color(0xFFD92E1A)});

  final Color brandColor;

  @override
  ConsumerState<XboardForgotPasswordPage> createState() =>
      _XboardForgotPasswordPageState();
}

class _XboardForgotPasswordPageState
    extends ConsumerState<XboardForgotPasswordPage> with WidgetsBindingObserver {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _obscure = true;
  bool _sending = false;
  bool _submitting = false;
  String? _emailError;
  String? _codeError;
  String? _passwordError;
  String? _confirmError;
  String? _banner;

  int _codeCooldown = 0; // 显示用剩余秒（wall clock 派生）
  Timer? _tickTimer;

  /// θ-7 monotonic throttle gate：上次发送以来的单调计时；null = 本会话未发送过。
  /// 改系统时间不影响 Stopwatch，故无法绕过 60s 放行判定。
  Stopwatch? _monotonicSinceSend;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreCooldown();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tickTimer?.cancel();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台从持久化 timestamp 重算剩余秒（R3.2.bis）。
    if (state == AppLifecycleState.resumed) _restoreCooldown();
  }

  /// 从持久化 timestamp 恢复显示倒计时（wall clock）。
  Future<void> _restoreCooldown() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(kLastSendEmailVerifyAtKey);
    if (last == null) return;
    final elapsed = (DateTime.now().millisecondsSinceEpoch - last) ~/ 1000;
    final remain = kEmailVerifyCooldownSeconds - elapsed;
    if (remain > 0 && mounted) {
      setState(() => _codeCooldown = remain);
      _startTick();
    }
  }

  void _startTick() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _codeCooldown--);
      if (_codeCooldown <= 0) timer.cancel();
    });
  }

  /// θ-7：是否允许发送（monotonic gate）。本会话发过且未满 60s → 拒绝（防改钟绕过）。
  bool get _throttleAllows {
    final sw = _monotonicSinceSend;
    if (sw == null) return true; // 本会话首次
    return sw.elapsed.inSeconds >= kEmailVerifyCooldownSeconds;
  }

  Future<void> _sendCode() async {
    if (_sending || _codeCooldown > 0 || !_throttleAllows) return;
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _emailError = '请先输入邮箱');
      return;
    }
    setState(() {
      _emailError = null;
      _banner = null;
      _sending = true;
    });

    final result = await ref.read(xboardServiceProvider).sendEmailVerifyCode(email);
    if (!mounted) return;
    setState(() => _sending = false);

    switch (result) {
      case XbSuccess():
        await _onCodeSent();
      case XbFailure(:final error):
        if (error is XbBusiness &&
            error.kind == BusinessErrorKind.emailVerifyCodeRateLimit) {
          // 后端已限流 → 同样起 60s 倒计时。
          await _onCodeSent();
        } else {
          _handleError(error);
        }
    }
  }

  Future<void> _onCodeSent() async {
    // 显示用：持久化 wall clock timestamp（R3.2.bis）。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        kLastSendEmailVerifyAtKey, DateTime.now().millisecondsSinceEpoch);
    // 安全用：重置 monotonic gate（θ-7）。
    _monotonicSinceSend = Stopwatch()..start();
    if (!mounted) return;
    setState(() {
      // θ-5：合并文案，不区分邮箱是否已注册（OWASP ASVS 5.1.1）。
      _banner = '如果该邮箱已注册，重置邮件已发送';
      _codeCooldown = kEmailVerifyCooldownSeconds;
    });
    _startTick();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final pw = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;
    setState(() {
      _emailError = email.isEmpty ? '请输入邮箱' : null;
      _codeError = code.isEmpty ? '请输入验证码' : null;
      _passwordError = pw.isEmpty ? '请输入新密码' : null;
      _confirmError = confirm != pw ? '两次密码不一致' : null;
      _banner = null;
    });
    if (_emailError != null ||
        _codeError != null ||
        _passwordError != null ||
        _confirmError != null) {
      return;
    }

    setState(() => _submitting = true);
    final result =
        await ref.read(xboardServiceProvider).forgotPassword(email, code, pw);
    if (!mounted) return;
    setState(() => _submitting = false);

    switch (result) {
      case XbSuccess():
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('密码重置成功')),
        );
        Navigator.of(context).maybePop(); // R3.4 跳回登录页
      case XbFailure(:final error):
        _handleError(error);
    }
  }

  void _handleError(XbDomainError error) {
    setState(() {
      switch (error) {
        case XbRateLimit(:final retryAfterMinutes):
          final mins = retryAfterMinutes ?? 5;
          _banner = '忘记密码请求过于频繁，请 $mins 分钟后重试';
        case XbBusiness(:final kind):
          if (kind == BusinessErrorKind.invalidEmailCode) {
            _codeError = '验证码错误或已过期';
          } else {
            _banner = error.message.isNotEmpty ? error.message : '重置失败，请稍后重试';
          }
        case XbNetwork():
          _banner = '网络异常，请检查网络后重试';
        case XbServer():
          _banner = '服务异常，请稍后重试';
        default:
          _banner = error.message.isNotEmpty ? error.message : '重置失败，请稍后重试';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
                        const Center(
                            child: XbBrandBadge(icon: Icons.lock_reset_rounded)),
                        const SizedBox(height: 24),
                        Text(
                          '重置密码',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '通过邮箱验证码重置你的登录密码',
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
                          enabled: !_submitting,
                          autofillHints: const [AutofillHints.email],
                        ),
                        const SizedBox(height: 16),
                        _buildCodeRow(),
                        const SizedBox(height: 16),
                        XbTextField(
                          label: '新密码',
                          controller: _passwordCtrl,
                          errorText: _passwordError,
                          prefixIcon: Icons.lock_outline_rounded,
                          obscureText: _obscure,
                          textInputAction: TextInputAction.next,
                          enabled: !_submitting,
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
                          label: '确认新密码',
                          controller: _confirmCtrl,
                          errorText: _confirmError,
                          prefixIcon: Icons.lock_outline_rounded,
                          obscureText: _obscure,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          enabled: !_submitting,
                        ),
                        const SizedBox(height: 24),
                        XbPrimaryButton(
                          label: '重置密码',
                          loading: _submitting,
                          onPressed: _submitting ? null : _submit,
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: TextButton(
                            onPressed: _submitting
                                ? null
                                : () => Navigator.of(context).maybePop(),
                            child: const Text('返回登录'),
                          ),
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

  Widget _buildCodeRow() {
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
            enabled: !_submitting,
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          height: 56,
          child: OutlinedButton(
            onPressed: (_sending || _codeCooldown > 0) ? null : _sendCode,
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: _sending
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_codeCooldown > 0 ? '${_codeCooldown}s' : '发送验证码'),
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
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: scheme.onSecondaryContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _banner!,
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
