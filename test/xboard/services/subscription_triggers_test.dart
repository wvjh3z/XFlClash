/// R4.6 step2b — SubscriptionTriggers：gate（bootstrapReady + authenticated）+ onResume 24h 节流。
///
/// onAuthenticated/onResume 收 ProviderContainer（始终存活接线，由 xboard_module 调）；
/// onManualRefresh 收 WidgetRef（UI 调）。聚焦「未就绪不触发」「就绪触发账号刷新」「onResume 节流」。
/// 用 userProfileProvider 的重拉次数（getSubscription 调用计数）作可观测信号。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/subscription_triggers.dart';

class _MockService extends Mock implements XboardService {}

class _ReadyStub extends BootstrapReady {
  _ReadyStub(this._v);
  final bool _v;
  @override
  bool build() => _v;
}

class _AuthStub extends AuthStateNotifier {
  _AuthStub(this._v);
  final AuthState _v;
  @override
  AuthState build() => _v;
}

void main() {
  late _MockService service;
  var getSubCalls = 0;

  setUp(() {
    service = _MockService();
    getSubCalls = 0;
    SubscriptionTriggers.resetResumeThrottle();
    when(() => service.getSubscription()).thenAnswer((_) async {
      getSubCalls++;
      return XbResult.success(const XbDomainSubscription(
          email: 'a@b.com', uuid: 'x', totalBytes: 1, usedBytes: 0));
    });
  });

  ProviderContainer makeContainer({required bool ready, required AuthState auth}) {
    final c = ProviderContainer(overrides: [
      xboardServiceProvider.overrideWithValue(service),
      bootstrapReadyProvider.overrideWith(() => _ReadyStub(ready)),
      authStateProvider.overrideWith(() => _AuthStub(auth)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  /// 等 userProfile 的 FutureProvider 跑完（getSubscription 计数稳定）。
  Future<void> settle(ProviderContainer c) async {
    // 主动消费 + 等微任务/异步完成。
    c.read(userProfileProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('未就绪（bootstrapReady=false）→ onAuthenticated no-op（不重拉账号）', () async {
    final c = makeContainer(ready: false, auth: AuthState.authenticated);
    await settle(c);
    final before = getSubCalls;
    SubscriptionTriggers.onAuthenticated(c);
    await settle(c);
    expect(getSubCalls, before); // 未就绪 → invalidate 未发生
  });

  test('游客（unauthenticated）→ onAuthenticated no-op', () async {
    final c = makeContainer(ready: true, auth: AuthState.unauthenticated);
    await settle(c);
    final before = getSubCalls;
    SubscriptionTriggers.onAuthenticated(c);
    await settle(c);
    expect(getSubCalls, before);
  });

  test('就绪 + 已登录 → onAuthenticated 重拉账号信息', () async {
    final c = makeContainer(ready: true, auth: AuthState.authenticated);
    await settle(c);
    final before = getSubCalls;
    SubscriptionTriggers.onAuthenticated(c); // invalidate userProfile
    await settle(c); // 重新消费 → 重拉
    expect(getSubCalls, greaterThan(before));
  });

  testWidgets('onManualRefresh（WidgetRef）→ 重拉账号信息', (t) async {
    late WidgetRef captured;
    await t.pumpWidget(ProviderScope(
      overrides: [
        xboardServiceProvider.overrideWithValue(service),
        bootstrapReadyProvider.overrideWith(() => _ReadyStub(true)),
        authStateProvider.overrideWith(() => _AuthStub(AuthState.authenticated)),
      ],
      child: Consumer(builder: (_, ref, __) {
        captured = ref;
        return const SizedBox.shrink();
      }),
    ));
    captured.read(userProfileProvider);
    await t.pump(const Duration(milliseconds: 20));
    final before = getSubCalls;
    SubscriptionTriggers.onManualRefresh(captured);
    await t.pump(const Duration(milliseconds: 20));
    captured.read(userProfileProvider);
    await t.pump(const Duration(milliseconds: 20));
    expect(getSubCalls, greaterThan(before));
  });

  test('onResume 24h 节流：首次放行，紧接第二次被节流', () async {
    final c = makeContainer(ready: true, auth: AuthState.authenticated);
    await settle(c);

    SubscriptionTriggers.onResume(c); // 首次放行 → invalidate
    await settle(c); // 重拉
    final afterFirst = getSubCalls;

    SubscriptionTriggers.onResume(c); // 节流窗口内 → no-op
    await settle(c);
    expect(getSubCalls, afterFirst); // 未再 invalidate（settle 的 read 命中缓存不增计数）
  });
}
