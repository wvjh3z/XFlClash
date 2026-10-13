import 'dart:async';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';
import 'package:fl_clash/xboard/util/subscription_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockSDK extends Mock implements XBoardSDK {}

class _MockAuthApi extends Mock implements AuthApi {}

class _MockSubscriptionApi extends Mock implements SubscriptionApi {}

class _MockPreferences extends Mock implements SharedPreferences {}

const _tokenA = 'account-a-fixture';
const _tokenB = 'account-b-fixture';

void main() {
  test(
    'a service retained from A cannot start a fresh request with B credentials',
    () async {
      final harness = _SessionHarness();
      harness.switchAccount();
      _expectCancelled(await harness.service.getSubscribeUrl());
      verifyNever(() => harness.subscription.getSubscribeUrl());
      expect(harness.token, _tokenB);
    },
  );

  test(
    'a later save of the same token cannot be cleared by an older login completion',
    () async {
      final harness = _SessionHarness();
      when(
        () => harness.auth.loginResult(any(), any()),
      ).thenAnswer((_) async => const Success('same-fixture'));
      when(() => harness.sdk.saveTokenIfSession(any(), any())).thenAnswer((
        _,
      ) async {
        harness.token = 'same-fixture';
        harness.revision++;
        final oldSave = harness.sdk.authSession;
        // 在旧调用续体得到其 snapshot 前，新登录已保存完全相同的 raw token。
        harness.revision++;
        return oldSave;
      });

      _expectCancelled(
        await harness.service.login('a@example.invalid', 'fixture-password'),
      );
      expect(harness.token, 'same-fixture');
      verifyNever(() => harness.sdk.clearToken());
      verifyNever(() => harness.sdk.clearTokenIfSession(any()));
    },
  );

  test(
    'same-owner late cache write cannot remove a new session cache',
    () async {
      final harness = _SessionHarness();
      final ownerKey = SubscriptionCache.keyFor(userIdHashFromToken(_tokenA));
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      var writes = 0;
      when(() => harness.preferences.setString(ownerKey, any())).thenAnswer((
        call,
      ) async {
        if (++writes == 1) {
          writeStarted.complete();
          await releaseWrite.future;
        }
        harness.values[ownerKey] = call.positionalArguments[1] as String;
        return true;
      });
      when(
        () => harness.subscription.getSubscription(),
      ).thenAnswer((_) async => _subscription('old session'));
      final requestOld = harness.service.getSubscription();
      await writeStarted.future;
      // 同 raw token 的新会话仍必须以 SDK revision 隔离。
      harness.revision++;
      when(
        () => harness.subscription.getSubscription(),
      ).thenAnswer((_) async => _subscription('new session'));
      final requestNew = harness.newService().getSubscription();
      await Future<void>.delayed(Duration.zero);
      releaseWrite.complete();
      _expectCancelled(await requestOld);
      expect((await requestNew).dataOrNull?.planName, 'new session');
      expect(harness.values[ownerKey], contains('new session'));
    },
  );

  test(
    'session end during token save cancels late login and removes its saved credential',
    () async {
      final harness = _SessionHarness();
      final saveStarted = Completer<void>();
      final releaseSave = Completer<void>();
      when(
        () => harness.auth.loginResult(any(), any()),
      ).thenAnswer((_) async => const Success('late-account-a-fixture'));
      when(() => harness.sdk.saveTokenIfSession(any(), any())).thenAnswer((
        _,
      ) async {
        saveStarted.complete();
        await releaseSave.future;
        harness.token = 'late-account-a-fixture';
        harness.revision++;
        return harness.sdk.authSession;
      });
      final login = harness.service.login(
        'a@example.invalid',
        'fixture-password',
      );
      await saveStarted.future;
      await harness.service.endSession(
        ownerHash: userIdHashFromToken(_tokenA),
        sdkRevision: harness.revision,
        expired: false,
      );
      releaseSave.complete();

      _expectCancelled(await login);
      expect(harness.token, isNull, reason: '已结束的登录不能留下晚到的持久化凭据');
    },
  );

  test(
    'A late success is cancelled while a new service returns B data',
    () async {
      final harness = _SessionHarness();
      final oldResult = Completer<String>();
      when(
        () => harness.subscription.getSubscribeUrl(),
      ).thenAnswer((_) => oldResult.future);
      final requestA = harness.service.getSubscribeUrl();

      harness.switchAccount();
      when(
        () => harness.subscription.getSubscribeUrl(),
      ).thenAnswer((_) async => 'subscription-b-fixture');
      final requestB = await harness.newService().getSubscribeUrl();
      expect(requestB.dataOrNull, 'subscription-b-fixture');
      oldResult.complete('subscription-a-fixture');
      _expectCancelled(await requestA);
      expect(harness.token, _tokenB);
    },
  );

  test(
    'A late 401 becomes cancellation instead of a B unauthorized error',
    () async {
      final harness = _SessionHarness();
      final oldResult = Completer<String>();
      when(
        () => harness.subscription.getSubscribeUrl(),
      ).thenAnswer((_) => oldResult.future);
      final requestA = harness.service.getSubscribeUrl();
      harness.switchAccount();
      oldResult.completeError(AuthException('account A expired', 401));

      _expectCancelled(await requestA);
      expect(harness.token, _tokenB);
      verifyNever(() => harness.sdk.clearToken());
      verifyNever(() => harness.sdk.clearTokenIfSession(any()));
    },
  );

  test(
    'account change during domain failover prevents old throw-path retry',
    () async {
      final harness = _SessionHarness();
      final failoverStarted = Completer<void>();
      final releaseFailover = Completer<void>();
      final service = harness.newService(
        apiFailover: () async {
          failoverStarted.complete();
          await releaseFailover.future;
        },
      );
      when(
        () => harness.subscription.getSubscribeUrl(),
      ).thenThrow(NetworkException('domain unavailable'));
      final request = service.getSubscribeUrl();
      await failoverStarted.future;
      harness.switchAccount();
      releaseFailover.complete();

      _expectCancelled(await request);
      verify(() => harness.subscription.getSubscribeUrl()).called(1);
      expect(harness.token, _tokenB);
    },
  );

  test(
    'account change during login failover prevents retry and token save',
    () async {
      final harness = _SessionHarness();
      final failoverStarted = Completer<void>();
      final releaseFailover = Completer<void>();
      final service = harness.newService(
        apiFailover: () async {
          failoverStarted.complete();
          await releaseFailover.future;
        },
      );
      when(() => harness.auth.loginResult(any(), any())).thenAnswer(
        (_) async => const Failure(
          NetworkError('domain unavailable', kind: NetworkErrorKind.timeout),
        ),
      );
      final request = service.login('a@example.invalid', 'fixture-password');
      await failoverStarted.future;
      harness.switchAccount();
      releaseFailover.complete();

      _expectCancelled(await request);
      verify(() => harness.auth.loginResult(any(), any())).called(1);
      verifyNever(() => harness.sdk.saveToken(any()));
      verifyNever(() => harness.sdk.saveTokenIfSession(any(), any()));
      expect(harness.token, _tokenB);
    },
  );

  test('A late login success cannot replace a B token', () async {
    final harness = _SessionHarness();
    final oldLogin = Completer<SdkResult<String>>();
    when(
      () => harness.auth.loginResult(any(), any()),
    ).thenAnswer((_) => oldLogin.future);
    final request = harness.service.login(
      'a@example.invalid',
      'fixture-password',
    );
    harness.switchAccount();
    oldLogin.complete(const Success('new-account-a-fixture'));

    _expectCancelled(await request);
    verifyNever(() => harness.sdk.saveToken(any()));
    verifyNever(() => harness.sdk.saveTokenIfSession(any(), any()));
    expect(harness.token, _tokenB);
  });

  test(
    'A subscription response arriving after account change never writes B cache',
    () async {
      final harness = _SessionHarness();
      final subscriptionStarted = Completer<void>();
      final oldSubscription = Completer<SubscriptionModel>();
      when(() => harness.subscription.getSubscription()).thenAnswer((_) {
        subscriptionStarted.complete();
        return oldSubscription.future;
      });
      final request = harness.service.getSubscription();
      await subscriptionStarted.future;
      harness.switchAccount();
      final bKey = SubscriptionCache.keyFor(userIdHashFromToken(_tokenB));
      harness.values[bKey] = 'existing B cache';
      oldSubscription.complete(_subscription('account A'));

      _expectCancelled(await request);
      expect(harness.values[bKey], 'existing B cache');
      verifyNever(() => harness.preferences.setString(any(), any()));
    },
  );

  test(
    'A cache write finishing after B cache removes only A owner entry',
    () async {
      final harness = _SessionHarness();
      final aKey = SubscriptionCache.keyFor(userIdHashFromToken(_tokenA));
      final bKey = SubscriptionCache.keyFor(userIdHashFromToken(_tokenB));
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      when(() => harness.preferences.setString(aKey, any())).thenAnswer((
        call,
      ) async {
        writeStarted.complete();
        await releaseWrite.future;
        harness.values[aKey] = call.positionalArguments[1] as String;
        return true;
      });
      when(
        () => harness.subscription.getSubscription(),
      ).thenAnswer((_) async => _subscription('account A'));
      final requestA = harness.service.getSubscription();
      await writeStarted.future;

      harness.switchAccount();
      when(
        () => harness.subscription.getSubscription(),
      ).thenAnswer((_) async => _subscription('account B'));
      final requestB = await harness.newService().getSubscription();
      expect(requestB.dataOrNull?.planName, 'account B');
      final bValue = harness.values[bKey];
      expect(bValue, isNotNull);
      releaseWrite.complete();
      _expectCancelled(await requestA);

      expect(harness.values[aKey], isNull);
      expect(harness.values[bKey], bValue);
      verify(() => harness.preferences.remove(aKey)).called(1);
      verifyNever(() => harness.preferences.remove(bKey));
    },
  );

  test(
    'old explicit session end conditionally clears A without affecting B',
    () async {
      final harness = _SessionHarness();
      final oldRevision = harness.revision;
      final ownerA = userIdHashFromToken(_tokenA);
      final aKey = SubscriptionCache.keyFor(ownerA);
      final bKey = SubscriptionCache.keyFor(userIdHashFromToken(_tokenB));
      harness.values.addAll({aKey: 'cache A', bKey: 'cache B'});
      harness.switchAccount();

      await harness.service.endSession(
        ownerHash: ownerA,
        sdkRevision: oldRevision,
        expired: false,
      );

      expect(harness.token, _tokenB);
      expect(harness.values[aKey], isNull);
      expect(harness.values[bKey], 'cache B');
      verify(() => harness.sdk.clearTokenIfSession(oldRevision)).called(1);
      verifyNever(() => harness.sdk.clearToken());
    },
  );

  test(
    'new login during slow A cache cleanup cannot be cleared afterwards',
    () async {
      final harness = _SessionHarness();
      final ownerA = userIdHashFromToken(_tokenA);
      final aKey = SubscriptionCache.keyFor(ownerA);
      final removeStarted = Completer<void>();
      final releaseRemove = Completer<void>();
      when(() => harness.preferences.remove(aKey)).thenAnswer((_) async {
        removeStarted.complete();
        await releaseRemove.future;
        harness.values.remove(aKey);
        return true;
      });
      final ending = harness.service.endSession(
        ownerHash: ownerA,
        sdkRevision: harness.revision,
        expired: false,
      );
      await removeStarted.future;
      expect(harness.token, isNull);
      harness.switchAccount();
      releaseRemove.complete();
      await ending;

      expect(harness.token, _tokenB);
      verify(() => harness.sdk.clearTokenIfSession(any())).called(1);
      verifyNever(() => harness.sdk.clearToken());
    },
  );

  test(
    'expired end clears retained A owner cache without clearing SDK again',
    () async {
      final harness = _SessionHarness();
      final oldRevision = harness.revision;
      final ownerA = userIdHashFromToken(_tokenA);
      final aKey = SubscriptionCache.keyFor(ownerA);
      final bKey = SubscriptionCache.keyFor(userIdHashFromToken(_tokenB));
      harness.values.addAll({aKey: 'cache A', bKey: 'cache B'});
      harness.token = null;
      harness.revision++;

      await harness.service.endSession(
        ownerHash: ownerA,
        sdkRevision: oldRevision,
        expired: true,
      );

      expect(harness.values[aKey], isNull);
      expect(harness.values[bKey], 'cache B');
      verifyNever(() => harness.sdk.clearToken());
      verifyNever(() => harness.sdk.clearTokenIfSession(any()));
      verifyNever(() => harness.sdk.getToken());
    },
  );

  test(
    'ended service remains blocked while replacement service can fetch B',
    () async {
      final harness = _SessionHarness();
      await harness.service.endSession(
        ownerHash: null,
        sdkRevision: harness.revision,
        expired: true,
      );
      harness.switchAccount();
      when(
        () => harness.subscription.getSubscribeUrl(),
      ).thenAnswer((_) async => 'subscription-b-fixture');
      _expectCancelled(await harness.service.getSubscribeUrl());
      expect(
        (await harness.newService().getSubscribeUrl()).dataOrNull,
        'subscription-b-fixture',
      );
      verify(() => harness.subscription.getSubscribeUrl()).called(1);
    },
  );

  test(
    'saveToken failure returns login failure without successful account data',
    () async {
      final harness = _SessionHarness();
      when(
        () => harness.auth.loginResult(any(), any()),
      ).thenAnswer((_) async => const Success('new-login-fixture'));
      when(
        () => harness.sdk.saveTokenIfSession(any(), any()),
      ).thenThrow(StateError('fixture storage unavailable'));

      final result = await harness.service.login(
        'a@example.invalid',
        'fixture-password',
      );
      expect(result, isA<XbFailure<String>>());
      expect(result.errorOrNull, isA<XbUnexpected>());
      expect(result.dataOrNull, isNull);
      expect(harness.token, _tokenA);
    },
  );
}

void _expectCancelled<T>(XbResult<T> result) {
  expect(result, isA<XbFailure<T>>());
  expect(result.errorOrNull, isA<XbNetwork>());
  expect((result.errorOrNull! as XbNetwork).kind, NetworkErrorKind.cancelled);
}

SubscriptionModel _subscription(String planName) => SubscriptionModel(
  email: 'fixture@example.invalid',
  uuid: 'fixture-uuid',
  plan: SubscriptionPlanModel(name: planName),
  transferEnable: 1000,
  u: 10,
  d: 20,
);

class _SessionHarness {
  _SessionHarness() {
    when(() => sdk.authSession).thenAnswer(
      (_) => AuthSessionSnapshot(
        revision: revision,
        state: token == null
            ? AuthState.unauthenticated
            : AuthState.authenticated,
      ),
    );
    when(() => sdk.getToken()).thenAnswer((_) async => token);
    when(() => sdk.auth).thenReturn(auth);
    when(() => sdk.subscription).thenReturn(subscription);
    when(() => sdk.saveTokenIfSession(any(), any())).thenAnswer((call) async {
      if (revision != call.positionalArguments[1]) return null;
      token = call.positionalArguments[0] as String;
      revision++;
      return sdk.authSession;
    });
    when(() => sdk.clearToken()).thenAnswer((_) async {
      token = null;
      revision++;
    });
    when(() => sdk.clearTokenIfSession(any())).thenAnswer((call) async {
      if (revision != call.positionalArguments.single) return false;
      token = null;
      revision++;
      return true;
    });
    when(
      () => preferences.getString(any()),
    ).thenAnswer((call) => values[call.positionalArguments.single as String]);
    when(() => preferences.setString(any(), any())).thenAnswer((call) async {
      values[call.positionalArguments[0] as String] =
          call.positionalArguments[1] as String;
      return true;
    });
    when(() => preferences.remove(any())).thenAnswer((call) async {
      values.remove(call.positionalArguments.single as String);
      return true;
    });
    service = newService();
  }

  final sdk = _MockSDK();
  final auth = _MockAuthApi();
  final subscription = _MockSubscriptionApi();
  final preferences = _MockPreferences();
  final values = <String, String>{};
  late final XboardServiceImpl service;
  String? token = _tokenA;
  int revision = 10;

  void switchAccount() {
    token = _tokenB;
    revision++;
  }

  XboardServiceImpl newService({Future<void> Function()? apiFailover}) =>
      XboardServiceImpl(
        sdk: sdk,
        subscriptionCache: SubscriptionCache(prefs: preferences),
        apiFailover: apiFailover,
      );
}
