/// R6 账号订阅数据 provider（design 状态管理表 = 唯一权威）。
///
/// **职责**：调反腐层 `getSubscription()`（getSubscribe 单端点 D27）拉账号订阅信息。
///
/// **keepAlive + Property 21**：keepAlive（不随 UI 重建丢数据）；endpoint 变化**不**自动
/// invalidate（Property 21：endpoint 热替换不重建已加载 UI），仅主动 `refresh()` / 下拉刷新
/// （R6.4）才重发。
///
/// **F14 防御（design L1467）**：调用方 UI 必须先 gate `authState == authenticated` 再 watch
/// 本 provider —— 游客态不应触发 getSubscription（会撞 R10 banner 误弹「登录已过期」）。
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/xb_domain_subscription.dart';
import '../models/xb_result.dart';
import 'xboard_providers.dart';
import 'auth_state_provider.dart';
import 'subscription_sync_status.dart';
import 'network_recovery_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show NotifierProvider, Notifier, Provider, FutureProvider;
import '../sdk/xboard_service.dart';
import '../util/subscription_cache.dart';

part '../generated/providers/user_profile_provider.g.dart';

/// HTTP recovery owns the retry budget; explicit refresh remains available.
Duration? noAutomaticAccountRetry(int retryCount, Object error) => null;

/// 账号订阅信息（R6）。success → 数据；failure → 抛 XbDomainError（UI 经 AsyncValue.error
/// 用 XboardStateView 分流，error 态按 7 子类型渲染）。
///
/// keepAlive：登录态期间常驻；logout / 切账号时调用方 `ref.invalidate` 清。
@Riverpod(keepAlive: true, retry: noAutomaticAccountRetry)
Future<XbDomainSubscription> userProfile(Ref ref) async {
  final auth = ref.read(authStateProvider.notifier);
  final revision = auth.sessionRevision;
  final service = ref.watch(xboardServiceProvider);
  final recovery = retryReadOnRecovery(ref, current: () =>
      ref.read(authStateProvider) == AuthState.authenticated &&
      auth.sessionRevision == revision && identical(ref.read(xboardServiceProvider), service));
  final result = await service.getSubscription();
  if (!ref.mounted || !identical(ref.read(authStateProvider.notifier), auth) ||
      auth.sessionRevision != revision ||
      !identical(ref.read(xboardServiceProvider), service)) {
    throw StateError('Account profile request superseded');
  }
  switch (result) {
    case XbSuccess(:final data):
      ref.read(lastAccountDisplayProvider.notifier).remember(revision, service, data);
      ref.read(nodeProfileHoldProvider.notifier).acceptFresh(revision, data);
      return data;
    case XbFailure(:final error):
      recovery(error);
      throw error;
  }
}

/// Display only. Never use this snapshot for connection, ordering or renewal.
typedef AccountDisplay = ({int revision, XboardService service, XbDomainSubscription data});
final lastAccountDisplayProvider = NotifierProvider<LastAccountDisplay, AccountDisplay?>(LastAccountDisplay.new);
class LastAccountDisplay extends Notifier<AccountDisplay?> {
  @override
  AccountDisplay? build() {
    ref.watch(authStateProvider);
    return null;
  }
  void remember(int revision, XboardService service, XbDomainSubscription data) {
    if (ref.read(authStateProvider) == AuthState.authenticated) {
      state = (revision: revision, service: service, data: data);
    }
  }
}

final staleAccountDisplayProvider = Provider<XbDomainSubscription?>((ref) {
  if (ref.watch(authStateProvider) != AuthState.authenticated) return null;
  final error = ref.watch(userProfileProvider).error;
  if (error != null && !xbIsRecoverableReadError(error)) return null;
  final last = ref.watch(lastAccountDisplayProvider) ?? ref.watch(_diskDisplay).asData?.value;
  if (last == null ||
      ref.read(authStateProvider.notifier).sessionRevision != last.revision ||
      !identical(ref.watch(xboardServiceProvider), last.service)) {
    return null;
  }
  return last.data;
});

final _diskDisplay = FutureProvider.autoDispose<AccountDisplay?>((ref) async {
  if (ref.watch(authStateProvider) != AuthState.authenticated) return null;
  final storage = ref.watch(injectedTokenStorageProvider);
  if (storage == null) return null;
  final service = ref.watch(xboardServiceProvider);
  final auth = ref.read(authStateProvider.notifier);
  final revision = auth.sessionRevision;
  try {
    final token = await storage.readToken();
    if (token == null || token.trim().isEmpty || !ref.mounted) return null;
    final data = await SubscriptionCache().read(token: token);
    if (!ref.mounted || data == null || auth.sessionRevision != revision ||
        !identical(ref.read(xboardServiceProvider), service)) {
      return null;
    }
    return (revision: revision, service: service, data: data);
  } catch (_) {
    return null;
  }
}, retry: noAutomaticAccountRetry);
