/// 形态 A 登录底部 sheet（spec `xboard-form-a-ui-revamp` / W5.1 / R5.1·R5.2·R5.3·R5.10）。
///
/// **渐进登录（R5.3）**：底部 sheet（不全屏拦截），游客可先浏览各页面再按需登录。
/// **gate（R5.2）**：`bootstrapReadyProvider` 未就绪时按钮禁用 +「准备中」（避免未就绪调反腐层抛 StateError）。
/// **复用形态 B（R5.10，◇）**：认证调 `xboardServiceProvider.login` + `authStateProvider` 编排
/// + token 存储，全链路零重写（自有代码不经 adapter）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/error_text.dart';
import 'package:fl_clash/xboard/widgets/xb_submit_guard.dart';

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

class _LoginSheetState extends ConsumerState<LoginSheet>
    with XbSubmitGuard<LoginSheet> {
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _obscure = true;
  String? _banner;
  bool _canRecheck = false;
  bool _checking = false;
  bool _checkSucceeded = false;
  int _checkGeneration = 0;

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_invalidateCheck);
    _pwCtrl.addListener(_invalidateCheck);
  }

  void _invalidateCheck() {
    _checkGeneration++;
    if (mounted && (_checking || _checkSucceeded)) {
      setState(() {
        _checking = false;
        _checkSucceeded = false;
        _banner = '账号或连接状态已变化，请重新检测线路。';
      });
    }
  }

  Future<void> _recheck() async {
    if (_checking ||
        submitting ||
        !_canRecheck ||
        !ref.read(bootstrapReadyProvider) ||
        ref.read(authStateProvider) == AuthState.authenticated) {
      return;
    }
    // A popped route stays mounted during its reverse animation. Reject it
    // synchronously, including navigation to registration/password recovery.
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent || !route.isActive) return;
    final race = ref.read(injectedRaceControllerProvider);
    final service = ref.read(xboardServiceProvider);
    final auth = ref.read(authStateProvider.notifier);
    final revision = auth.sessionRevision;
    final generation = ++_checkGeneration;
    bool current() =>
        mounted &&
        route.isCurrent &&
        route.isActive &&
        generation == _checkGeneration &&
        auth.sessionRevision == revision &&
        identical(ref.read(authStateProvider.notifier), auth) &&
        ref.read(bootstrapReadyProvider) &&
        ref.read(authStateProvider) != AuthState.authenticated &&
        identical(ref.read(xboardServiceProvider), service) &&
        identical(ref.read(injectedRaceControllerProvider), race);
    setState(() {
      _checking = true;
      _checkSucceeded = false;
      _banner = '正在检测可用线路，请稍候…';
    });
    final found = race == null
        ? false
        : await race.recheckApi(current: current);
    if (!current()) return;
    setState(() {
      _checking = false;
      _checkSucceeded = found == true;
      _banner = found == true
          ? '线路已更新，请重新登录。'
          : found == null
          ? '连接状态已变化，请重新检测线路。'
          : '暂未找到可用线路，请稍后重试或向客服反馈。';
    });
  }

  @override
  void dispose() {
    _checkGeneration++;
    _emailCtrl.removeListener(_invalidateCheck);
    _pwCtrl.removeListener(_invalidateCheck);
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking || submitting || !ref.read(bootstrapReadyProvider)) return;
    _checkGeneration++;
    _canRecheck = false;
    _checkSucceeded = false;
    final email = _emailCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (email.isEmpty || pw.isEmpty) {
      setState(() => _banner = '请输入邮箱和密码');
      return;
    }
    setState(() => _banner = null);
    await runSubmit(() async {
      final auth = ref.read(authStateProvider.notifier);
      final attempt = auth.startAuthenticating();
      await auth.waitForSessionCleanup();
      if (!mounted || !auth.isAuthenticationCurrent(attempt)) return;
      final result = await ref.read(xboardServiceProvider).login(email, pw);
      if (!mounted) return;
      switch (result) {
        case XbSuccess(:final data):
          final established = await auth.completeAuthentication(
            token: data,
            attempt: attempt,
          );
          if (!mounted) return;
          if (established) {
            Navigator.of(context).pop();
          } else if (auth.isAuthenticationCurrent(attempt)) {
            auth.failAuthentication(attempt);
            setState(() => _banner = '登录信息保存失败或已过期，请重试');
          }
        case XbFailure(:final error):
          if (!auth.isAuthenticationCurrent(attempt)) return;
          auth.failAuthentication(attempt);
          setState(() {
            _canRecheck =
                error is XbNetwork || error is XbServer || error is XbSecurity;
            _banner = _canRecheck
                ? '暂时无法连接登录服务，可重新检测线路。'
                : resolveErrorText(error, fallback: '登录失败，请重试');
          });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // R5.2 gate：bootstrap 未就绪 → 登录禁用。
    final ready = ref.watch(bootstrapReadyProvider);
    ref.listen(authStateProvider, (_, _) => _invalidateCheck());
    ref.listen(authStateProvider.notifier, (_, _) => _invalidateCheck());
    ref.listen(xboardServiceProvider, (_, _) => _invalidateCheck());
    ref.listen(injectedRaceControllerProvider, (_, _) => _invalidateCheck());
    ref.listen(bootstrapReadyProvider, (_, _) => _invalidateCheck());

    return XbSheetScaffold(
      title: '登录 ${XboardConfig.current.appName}',
      subtitle: '登录后同步你的专属节点',
      banner: _canRecheck ? null : _banner,
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
        if (_canRecheck && _banner != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color:
                  (_checkSucceeded
                          ? Colors.green
                          : Theme.of(context).colorScheme.error)
                      .withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                if (_checking)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    _checkSucceeded
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    size: 18,
                  ),
                const SizedBox(width: 8),
                Expanded(child: Text(_banner!)),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: (!ready || _checking || submitting)
                      ? null
                      : _recheck,
                  child: Text(_checking ? '检测中…' : '重新检测'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: '邮箱账号'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
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
            onPressed: (!ready || submitting || _checking) ? null : _submit,
            child: submitting
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
