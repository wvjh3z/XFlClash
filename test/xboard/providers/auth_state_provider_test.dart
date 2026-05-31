/// W3.2.7 — AuthState 3 态状态机全 transition 覆盖（§ G ε7）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';

void main() {
  late ProviderContainer c;
  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  AuthState read() => c.read(authStateProvider);
  AuthStateNotifier notifier() => c.read(authStateProvider.notifier);

  test('默认 unauthenticated', () {
    expect(read(), AuthState.unauthenticated);
  });

  test('unauthenticated → authenticating（login/register 发起）', () {
    notifier().startAuthenticating();
    expect(read(), AuthState.authenticating);
  });

  test('authenticating → authenticated（SDK Success）', () {
    notifier().startAuthenticating();
    notifier().markAuthenticated();
    expect(read(), AuthState.authenticated);
  });

  test('authenticating → unauthenticated（SDK Failure）', () {
    notifier().startAuthenticating();
    notifier().markUnauthenticated();
    expect(read(), AuthState.unauthenticated);
  });

  test('authenticated → unauthenticated（401/403 或主动登出）', () {
    notifier().markAuthenticated();
    notifier().markUnauthenticated();
    expect(read(), AuthState.unauthenticated);
  });

  test('401 尾递归保护：unauthenticated 时再 markUnauthenticated 是 no-op', () {
    // 监听 state 变化次数
    final changes = <AuthState>[];
    c.listen<AuthState>(authStateProvider,
        (AuthState? prev, AuthState next) => changes.add(next),
        fireImmediately: false);

    notifier().markAuthenticated(); // → authenticated (change 1)
    notifier().markUnauthenticated(); // → unauthenticated (change 2)
    notifier().markUnauthenticated(); // no-op（已 unauthenticated）
    notifier().markUnauthenticated(); // no-op

    expect(read(), AuthState.unauthenticated);
    // 只有 2 次真实变化（第 3、4 次是 no-op）
    expect(changes, [AuthState.authenticated, AuthState.unauthenticated]);
  });

  test('完整 mermaid 路径：默认→authenticating→authenticated→unauthenticated', () {
    expect(read(), AuthState.unauthenticated);
    notifier().startAuthenticating();
    expect(read(), AuthState.authenticating);
    notifier().markAuthenticated();
    expect(read(), AuthState.authenticated);
    notifier().markUnauthenticated();
    expect(read(), AuthState.unauthenticated);
  });
}
