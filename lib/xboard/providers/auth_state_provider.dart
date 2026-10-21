/// 客户端登录态及会话结束编排。SDK revision 防旧事件，本地 revision 防旧业务写入。
library;

import 'dart:async';

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    as sdk
    show XBoardSDK, AuthSessionChange, AuthSessionChangeReason, AuthState;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../sdk/xboard_service.dart';
import '../services/sentry_bootstrap.dart';
import '../services/subscription_triggers.dart';
import '../util/pii_mask.dart';
import 'auth_expiry_notice_provider.dart';
import 'invite_provider.dart';
import 'pending_order_provider.dart';
import 'user_profile_provider.dart';
import 'xboard_providers.dart';

part '../generated/providers/auth_state_provider.g.dart';

enum AuthState { unauthenticated, authenticating, authenticated }

@Riverpod(keepAlive: true)
class AuthStateNotifier extends _$AuthStateNotifier {
  sdk.XBoardSDK? _sdk;
  StreamSubscription<sdk.AuthSessionChange>? _sessionListener;
  int _revision = 0;
  int _authAttempt = 0;
  int? _sdkRevision;
  String? _ownerHash;
  Future<void>? _ending;

  /// 客户端业务世代；建立/结束会话都会变化，不等同于 SDK revision。
  int get sessionRevision => _revision;

  @override
  AuthState build() {
    ref.onDispose(unbindSdkSessions);
    return AuthState.unauthenticated;
  }

  void _set(AuthState next) {
    state = next;
    SentryBootstrap.tagAuthState(next.name);
  }

  /// 由模块在 SDK 初始化后、恢复登录态前绑定，模块释放时摘除。
  void bindSdkSessions(sdk.XBoardSDK instance) {
    unbindSdkSessions();
    _sdk = instance;
    _sessionListener = instance.authSessionChanges.listen((change) {
      if (!ref.mounted || _sdkRevision == null || _ownerHash == null) return;
      if (change.reason == sdk.AuthSessionChangeReason.signedIn) return;
      final current = instance.authSession;
      if (_sdkRevision != change.previous.revision ||
          current.revision != change.current.revision ||
          current.state != sdk.AuthState.unauthenticated) {
        return;
      }
      unawaited(
        _endSession(
          expired: change.reason == sdk.AuthSessionChangeReason.expired,
          tokenAlreadyCleared: true,
        ),
      );
    });
  }

  void unbindSdkSessions() {
    unawaited(_sessionListener?.cancel());
    _sessionListener = null;
    _sdk = null;
  }

  Future<void> waitForSessionCleanup() => _ending ?? Future<void>.value();

  int startAuthenticating() {
    _authAttempt++;
    _set(AuthState.authenticating);
    return _authAttempt;
  }

  bool isAuthenticationCurrent(int attempt) =>
      ref.mounted &&
      _authAttempt == attempt &&
      state == AuthState.authenticating;

  void failAuthentication(int attempt) {
    if (!isAuthenticationCurrent(attempt)) return;
    final current = _sdk?.authSession;
    if (_ownerHash != null &&
        current?.revision == _sdkRevision &&
        current?.state == sdk.AuthState.authenticated) {
      _set(AuthState.authenticated);
    } else {
      markUnauthenticated();
    }
  }

  /// 兼容不依赖 SDK 的展示/组件测试；生产登录与冷恢复使用 completeAuthentication。
  void markAuthenticated() {
    _authAttempt++;
    _revision++;
    _set(AuthState.authenticated);
  }

  /// 保存归属后才启动已登录业务。旧清理未结束时不允许新账号开始 Profile 同步。
  Future<bool> completeAuthentication({String? token, int? attempt}) async {
    if (attempt != null && !isAuthenticationCurrent(attempt)) return false;
    final instance = _sdk ?? ref.read(xboardSdkProvider);
    try {
      final snapshot = instance?.authSession;
      final raw = instance == null ? token : await instance.getToken();
      String? normalize(String? value) =>
          value?.replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
      if (token != null && normalize(token) != normalize(raw)) return false;
      if (attempt != null && !isAuthenticationCurrent(attempt)) return false;
      if (snapshot != null &&
          (snapshot.state != sdk.AuthState.authenticated || raw == null)) {
        return false;
      }
      if (_ownerHash != null && _sdkRevision != snapshot?.revision) {
        // 直接换号也必须先结束 A。SDK 已保存 B 时，条件清除 A revision 会保留 B。
        final cleanup = _endSession(expired: false);
        if (attempt != null) attempt = _authAttempt;
        await cleanup;
      }
      final ending = _ending;
      if (ending != null) await ending;
      if (!ref.mounted) return false;
      if (attempt != null && _authAttempt != attempt) return false;
      if (instance != null &&
          (instance.authSession.revision != snapshot!.revision ||
              instance.authSession.state != sdk.AuthState.authenticated)) {
        return false;
      }
      final normalized = normalize(raw);
      if (state == AuthState.authenticated &&
          _sdkRevision == snapshot?.revision &&
          _ownerHash ==
              (normalized == null ? null : userIdHashFromToken(normalized))) {
        return true;
      }
      _ownerHash = normalized == null ? null : userIdHashFromToken(normalized);
      _sdkRevision = snapshot?.revision;
      _authAttempt++;
      _revision++;
      if (instance != null) {
        // guest/login service 绑定旧 SDK revision。建立身份前重建，所有旧持有者
        // 都无法在 B token 已保存、A 清理尚未开始的窗口发起 B 的请求。
        ref.invalidate(subscriptionServiceProvider);
        ref.invalidate(xboardServiceProvider);
      }
      _set(AuthState.authenticated);
      return true;
    } catch (e, s) {
      SentryBootstrap.captureException(
        e,
        stackTrace: s,
        where: 'auth establish',
      );
      return false;
    }
  }

  void markUnauthenticated() {
    if (state == AuthState.unauthenticated) return;
    _revision++;
    _set(AuthState.unauthenticated);
  }

  Future<void> logout() => _endSession(expired: false);

  Future<void> _endSession({
    required bool expired,
    bool tokenAlreadyCleared = false,
  }) {
    final ending = _ending;
    if (ending != null) return ending;
    if (state == AuthState.unauthenticated && _ownerHash == null) {
      return Future<void>.value();
    }
    final owner = _ownerHash;
    final sdkRevision = _sdkRevision;
    XboardService? service;
    try {
      service = ref.read(xboardServiceProvider);
    } catch (e, s) {
      SentryBootstrap.captureException(
        e,
        stackTrace: s,
        where: 'auth cleanup service',
      );
    }
    final lifecycle = service is XboardSessionLifecycle
        ? service as XboardSessionLifecycle
        : null;
    lifecycle?.invalidateSessionRequests();
    _revision++;
    _authAttempt++;
    _ownerHash = null;
    _sdkRevision = null;
    _set(AuthState.unauthenticated);

    // 调用立即锁住旧订阅实例，再 invalidate；不能先 await Token 或慢下载。
    final profiles = _cleanup('auth cleanup profiles', () async {
      final subscriptions = ref.read(subscriptionServiceProvider);
      if (owner != null) {
        await subscriptions.clearForSessionOwner(owner);
      } else {
        await subscriptions.clearForCurrentUser(); // 无 SDK 的旧调用/测试兼容。
      }
    });
    final credentials = _cleanup('auth cleanup credentials', () async {
      if (lifecycle != null) {
        await lifecycle.endSession(
          ownerHash: owner,
          sdkRevision: sdkRevision,
          expired: expired || tokenAlreadyCleared,
        );
      } else if (!expired && !tokenAlreadyCleared) {
        // 旧实现需在按当前 Token 捕获 Profile 归属后再清 Token。
        await profiles;
        await service?.logout();
      }
    });
    ref.invalidate(userProfileProvider);
    ref.invalidate(pendingOrderProvider);
    ref.invalidate(inviteInfoProvider);
    ref.invalidate(commissionRecordsProvider);
    ref.invalidate(withdrawConfigProvider);
    SubscriptionTriggers.resetResumeThrottle();
    if (expired) ref.read(authExpiryNoticeProvider.notifier).notifyExpired();
    late final Future<void> future;
    future = Future.wait<void>([profiles, credentials]).then<void>((_) {
      // 旧 port 的 Ref 在 owned Profile 停用/删除期间必须存活。
      // 新登录等待此 Future，重建后才能开启新一代订阅同步。
      if (ref.mounted) {
        ref.invalidate(subscriptionServiceProvider);
        ref.invalidate(xboardServiceProvider);
      }
    }).whenComplete(() {
      if (identical(_ending, future)) _ending = null;
    });
    // Callers share the full cleanup Future, including release of _ending.
    _ending = future;
    return future;
  }

  static Future<void> _cleanup(
    String where,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e, s) {
      // 身份已结束，仍记录未清理资源；不把失败当成成功或恢复旧登录态。
      SentryBootstrap.captureException(e, stackTrace: s, where: where);
    }
  }

  /// 兼容入口。生产自动失效仅消费经过 SDK revision 校验的会话事件。
  void handleUnauthorized() => markUnauthenticated();
}
