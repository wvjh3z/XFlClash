/// SDK 事件与客户端编排的集成边界：用受控会话和清理 Future，无真实账号/网络。
library;

import 'dart:async';

import 'package:fl_clash/xboard/providers/auth_expiry_notice_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:mocktail/mocktail.dart';

class _Sdk extends Mock implements sdk.XBoardSDK {}

class _Subscriptions extends Mock implements XboardSubscriptionService {}

class _Service extends Mock implements XboardService, XboardSessionLifecycle {
  int invalidations = 0;
  final endings = <({String? owner, int? revision, bool expired})>[];

  @override
  void invalidateSessionRequests() => invalidations++;

  @override
  Future<void> endSession({
    required String? ownerHash,
    required int? sdkRevision,
    required bool expired,
  }) async {
    endings.add((owner: ownerHash, revision: sdkRevision, expired: expired));
  }
}

class _Fixture {
  final instance = _Sdk();
  final subscriptions = _Subscriptions();
  final service = _Service();
  final changes = StreamController<sdk.AuthSessionChange>.broadcast();
  sdk.AuthSessionSnapshot snapshot = const sdk.AuthSessionSnapshot(
    revision: 1,
    state: sdk.AuthState.authenticated,
  );
  String? token = 'account-a-test-token';
  late final ProviderContainer container;
  Completer<void>? cleanup;
  final cleanedOwners = <String>[];
  bool subscriptionDisposed = false;

  _Fixture() {
    when(() => instance.authSession).thenAnswer((_) => snapshot);
    when(() => instance.authSessionChanges).thenAnswer((_) => changes.stream);
    when(() => instance.getToken()).thenAnswer((_) async => token);
    when(() => subscriptions.clearForSessionOwner(any())).thenAnswer((
      call,
    ) async {
      cleanedOwners.add(call.positionalArguments[0] as String);
      await cleanup?.future;
    });
    container = ProviderContainer(
      overrides: [
        xboardServiceProvider.overrideWithValue(service),
        subscriptionServiceProvider.overrideWith((ref) {
          ref.onDispose(() => subscriptionDisposed = true);
          return subscriptions;
        }),
      ],
    );
    container.read(xboardSdkProvider.notifier).set(instance);
    auth.bindSdkSessions(instance);
  }

  AuthStateNotifier get auth => container.read(authStateProvider.notifier);
  AuthState get state => container.read(authStateProvider);
  int get notices => container.read(authExpiryNoticeProvider);

  Future<void> signInA() async {
    expect(await auth.completeAuthentication(), isTrue);
  }

  sdk.AuthSessionChange expire({
    sdk.AuthSessionChangeReason reason = sdk.AuthSessionChangeReason.expired,
  }) {
    final previous = snapshot;
    token = null;
    snapshot = sdk.AuthSessionSnapshot(
      revision: previous.revision + 1,
      state: sdk.AuthState.unauthenticated,
    );
    final event = sdk.AuthSessionChange(
      previous: previous,
      current: snapshot,
      reason: reason,
    );
    changes.add(event);
    return event;
  }

  void saveB({String value = 'account-b-test-token'}) {
    token = value;
    snapshot = sdk.AuthSessionSnapshot(
      revision: snapshot.revision + 1,
      state: sdk.AuthState.authenticated,
    );
  }

  Future<void> close() async {
    container.dispose();
    await changes.close();
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());
  tearDown(() => f.close());

  test('同一SDK快照重复完成认证不换业务世代或重复清理', () async {
    await f.signInA();
    final revision = f.auth.sessionRevision;
    expect(await f.auth.completeAuthentication(), isTrue);
    expect(f.auth.sessionRevision, revision);
    expect(f.cleanedOwners, isEmpty);
  });

  test('冷恢复保留A归属，SDK已清Token后一次统一退出与提示', () async {
    await f.signInA();
    final revision = f.auth.sessionRevision;
    final event = f.expire();
    f.changes.add(event);
    await _flush();
    await f.auth.waitForSessionCleanup();
    expect(f.state, AuthState.unauthenticated);
    expect(f.auth.sessionRevision, greaterThan(revision));
    expect(f.notices, 1);
    expect(f.cleanedOwners, [userIdHashFromToken('account-a-test-token')]);
    expect(f.service.endings.single, (
      owner: userIdHashFromToken('account-a-test-token'),
      revision: 1,
      expired: true,
    ));
    verifyNever(() => f.instance.clearToken());
  });

  test('SDK事件晚到时B已建立，不清B归属或触发旧导航', () async {
    await f.signInA();
    f.expire();
    f.saveB();
    expect(await f.auth.completeAuthentication(token: f.token), isTrue);
    await _flush();
    expect(f.state, AuthState.authenticated);
    expect(f.notices, 0);
    // complete本身先清A；旧expired事件不能再追加一次清理。
    expect(f.cleanedOwners, [userIdHashFromToken('account-a-test-token')]);
    expect(f.service.endings, hasLength(1));
    expect(f.service.endings.single.expired, isFalse);
  });

  test('B登录等待旧Profile清理，停用所需Ref保留到清理完成', () async {
    await f.signInA();
    f.cleanup = Completer<void>();
    f.expire();
    await _flush();
    expect(f.state, AuthState.unauthenticated);
    expect(f.subscriptionDisposed, isFalse);
    f.saveB();
    final attempt = f.auth.startAuthenticating();
    var completed = false;
    final newSession = f.auth
        .completeAuthentication(token: f.token, attempt: attempt)
        .then((value) {
          completed = true;
          return value;
        });
    await _flush();
    expect(completed, isFalse);
    expect(f.state, AuthState.authenticating);
    f.cleanup!.complete();
    expect(await newSession, isTrue);
    expect(f.subscriptionDisposed, isTrue);
    expect(f.state, AuthState.authenticated);
    expect(f.token, 'account-b-test-token');
  });

  test('主动退出合并重复调用，只清旧revision且无过期提示', () async {
    await f.signInA();
    f.cleanup = Completer<void>();
    final first = f.auth.logout();
    final second = f.auth.logout();
    expect(identical(first, second), isTrue);
    expect(f.state, AuthState.unauthenticated);
    f.cleanup!.complete();
    await Future.wait([first, second]);
    expect(f.service.endings.single.expired, isFalse);
    expect(f.service.endings.single.revision, 1);
    expect(f.cleanedOwners, hasLength(1));
    expect(f.notices, 0);
  });

  test('清理失败不复活登录，仍尝试凭据缓存清理', () async {
    await f.signInA();
    when(
      () => f.subscriptions.clearForSessionOwner(any()),
    ).thenThrow(StateError('controlled profile failure'));
    f.expire();
    await _flush();
    await f.auth.waitForSessionCleanup();
    expect(f.state, AuthState.unauthenticated);
    expect(f.notices, 1);
    expect(f.service.endings, hasLength(1));
  });

  test('清理中容器dispose，晚到完成不访问已释放Ref', () async {
    await f.signInA();
    f.cleanup = Completer<void>();
    final ending = f.auth.logout();
    f.container.dispose();
    f.cleanup!.complete();
    await expectLater(ending, completes);
  });

  test('SDK主动signedOut统一本地清理，不显示认证过期提示', () async {
    await f.signInA();
    f.expire(reason: sdk.AuthSessionChangeReason.signedOut);
    await _flush();
    await f.auth.waitForSessionCleanup();
    expect(f.state, AuthState.unauthenticated);
    expect(f.notices, 0);
    expect(f.service.endings.single.expired, isTrue); // Token已清，不二次删除。
  });

  test('旧登录token与SDK当前B不匹配，不能绑A归属或建立登录态', () async {
    f.saveB();
    expect(
      await f.auth.completeAuthentication(token: 'account-a-test-token'),
      isFalse,
    );
    expect(f.state, AuthState.unauthenticated);
    expect(f.cleanedOwners, isEmpty);
  });

  test('旧登录失败回写不能把已建立B切为游客', () async {
    final oldAttempt = f.auth.startAuthenticating();
    final newAttempt = f.auth.startAuthenticating();
    f.saveB();
    expect(
      await f.auth.completeAuthentication(token: f.token, attempt: newAttempt),
      isTrue,
    );
    f.auth.failAuthentication(oldAttempt);
    expect(f.state, AuthState.authenticated);
    expect(
      await f.auth.completeAuthentication(
        token: 'account-a-test-token',
        attempt: oldAttempt,
      ),
      isFalse,
    );
    expect(f.state, AuthState.authenticated);
  });

  test('A仍有归属但正处于authenticating，A失效也必须清旧资源', () async {
    await f.signInA();
    final attempt = f.auth.startAuthenticating();
    f.expire();
    await _flush();
    await f.auth.waitForSessionCleanup();
    expect(f.state, AuthState.unauthenticated);
    expect(f.cleanedOwners, [userIdHashFromToken('account-a-test-token')]);
    expect(f.notices, 1);
    f.auth.failAuthentication(attempt);
    expect(f.state, AuthState.unauthenticated);
  });
}
