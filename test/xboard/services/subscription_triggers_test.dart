/// R4.6 step2b — SubscriptionTriggers：gate（bootstrapReady + authenticated）+ onResume 24h 节流。
///
/// 不验证真实 sync（subscriptionServiceProvider 需 tokenStorage 注入，gate 未过时根本不触达）；
/// 聚焦「未就绪不触发」「就绪触发账号刷新」「onResume 节流」三类行为，用 userProfileProvider 的
/// 重拉次数作可观测信号。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/subscription_triggers.dart';

import 'package:mocktail/mocktail.dart';

class _MockService extends Mock implements XboardService {}

/// 暴露 WidgetRef 给 SubscriptionTriggers（其 API 收 WidgetRef）。
class _Harness extends ConsumerWidget {
  const _Harness(this.onRef);
  final void Function(WidgetRef ref) onRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    return const SizedBox.shrink();
  }
}

void main() {
  late _MockService service;
  var getSubCalls = 0;

  setUp(() {
    service = _MockService();
    getSubCalls = 0;
    SubscriptionTriggers.debugResetThrottle();
    when(() => service.getSubscription()).thenAnswer((_) async {
      getSubCalls++;
      return XbResult.success(
          const XbDomainSubscription(email: 'a@b.com', uuid: 'x', totalBytes: 1, usedBytes: 0));
    });
  });

  /// pump 一个 harness，拿到 WidgetRef + 可控 bootstrapReady / authState override。
  Future<WidgetRef> pumpRef(
    WidgetTester t, {
    required bool ready,
    required AuthState auth,
  }) async {
    late WidgetRef captured;
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          xboardServiceProvider.overrideWithValue(service),
          bootstrapReadyProvider.overrideWith(() => _ReadyStub(ready)),
          authStateProvider.overrideWith(() => _AuthStub(auth)),
        ],
        child: _Harness((ref) => captured = ref),
      ),
    );
    // 触发一次 userProfile watch 计数基线（消费 provider）。
    return captured;
  }

  testWidgets('未就绪（bootstrapReady=false）→ onAuthenticated no-op（不重拉账号）', (t) async {
    final ref = await pumpRef(t, ready: false, auth: AuthState.authenticated);
    ref.read(userProfileProvider); // 建立首次拉取
    await t.pump(const Duration(milliseconds: 20));
    final before = getSubCalls;
    SubscriptionTriggers.onAuthenticated(ref);
    await t.pump(const Duration(milliseconds: 20));
    expect(getSubCalls, before); // 未就绪 → invalidate 未发生
  });

  testWidgets('游客（unauthenticated）→ onAuthenticated no-op', (t) async {
    final ref = await pumpRef(t, ready: true, auth: AuthState.unauthenticated);
    ref.read(userProfileProvider);
    await t.pump(const Duration(milliseconds: 20));
    final before = getSubCalls;
    SubscriptionTriggers.onAuthenticated(ref);
    await t.pump(const Duration(milliseconds: 20));
    expect(getSubCalls, before);
  });

  testWidgets('就绪 + 已登录 → onManualRefresh 重拉账号信息', (t) async {
    final ref = await pumpRef(t, ready: true, auth: AuthState.authenticated);
    ref.read(userProfileProvider);
    await t.pump(const Duration(milliseconds: 20));
    final before = getSubCalls;
    SubscriptionTriggers.onManualRefresh(ref);
    await t.pump(const Duration(milliseconds: 20));
    ref.read(userProfileProvider); // 重新消费触发重拉
    await t.pump(const Duration(milliseconds: 20));
    expect(getSubCalls, greaterThan(before)); // invalidate → 重拉
  });

  testWidgets('onResume 24h 节流：首次放行，紧接第二次被节流', (t) async {
    final ref = await pumpRef(t, ready: true, auth: AuthState.authenticated);
    ref.read(userProfileProvider);
    await t.pump(const Duration(milliseconds: 20));

    // 首次 onResume → 放行（invalidate）。
    SubscriptionTriggers.onResume(ref);
    await t.pump(const Duration(milliseconds: 20));
    ref.read(userProfileProvider);
    await t.pump(const Duration(milliseconds: 20));
    final afterFirst = getSubCalls;

    // 紧接第二次 onResume（节流窗口内）→ no-op。
    SubscriptionTriggers.onResume(ref);
    await t.pump(const Duration(milliseconds: 20));
    ref.read(userProfileProvider);
    await t.pump(const Duration(milliseconds: 20));
    // 第二次被节流：不应再次 invalidate（重拉次数不增，除了上面 read 的缓存命中）。
    expect(getSubCalls, afterFirst);
  });
}

/// bootstrapReady override stub。
class _ReadyStub extends BootstrapReady {
  _ReadyStub(this._v);
  final bool _v;
  @override
  bool build() => _v;
}

/// authState override stub。
class _AuthStub extends AuthStateNotifier {
  _AuthStub(this._v);
  final AuthState _v;
  @override
  AuthState build() => _v;
}
