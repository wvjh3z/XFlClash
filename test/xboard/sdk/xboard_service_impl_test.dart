/// W2.2 + W2.4 — XboardServiceImpl 注入式 + _mapError 双形态归一单测。
///
/// 覆盖：
/// - 注入式构造（决策 #9）：fake XBoardSDK 注入
/// - SdkResult 形态归一（login）：Success → XbSuccess / Failure → XbFailure(_mapError)
/// - throw 形态归一（getSubscription）：正常 → XbSuccess / 抛 SdkError → 映射
/// - _mapError 7 子类映射正确（经 login Failure 各 SdkError 子类驱动）
/// - 永不抛（Property 1）：任意 SDK 形态 → 返 XbResult
/// - 未填实方法返 XbUnexpected('not_implemented')

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';

import '../../_fixtures/fake_xboard_sdk.dart';

void main() {
  late FakeXBoardSDK sdk;
  late FakeSubApis apis;
  late XboardServiceImpl service;

  setUp(() {
    SharedPreferences.setMockInitialValues({}); // W4.4 getSubscription 缓存写
    sdk = FakeXBoardSDK();
    apis = sdk.setupFor(XbScenario.loggedIn);
    service = XboardServiceImpl(sdk: sdk);
  });

  group('login（SdkResult 形态归一）', () {
    test('Success → XbSuccess(token)', () async {
      when(() => apis.authApi.loginResult(any(), any()))
          .thenAnswer((_) async => const Success('bearer-token'));
      final r = await service.login('A@B.com', 'pw');
      expect(r, isA<XbSuccess<String>>());
      expect((r as XbSuccess<String>).data, 'bearer-token');
    });

    test('D69 email 预处理（trim + lowercase）', () async {
      when(() => apis.authApi.loginResult(any(), any()))
          .thenAnswer((_) async => const Success('t'));
      await service.login('  A@B.com  ', 'pw');
      verify(() => apis.authApi.loginResult('a@b.com', 'pw')).called(1);
    });

    test('Failure(UnauthorizedError) → XbFailure(XbUnauthorized)', () async {
      when(() => apis.authApi.loginResult(any(), any()))
          .thenAnswer((_) async => const Failure(UnauthorizedError('未登录')));
      final r = await service.login('a@b.com', 'pw');
      expect((r as XbFailure).error, isA<XbUnauthorized>());
    });

    test('W3.9：成功登录 → 显式 saveToken（F406，loginResult 不自动存）', () async {
      when(() => apis.authApi.loginResult(any(), any()))
          .thenAnswer((_) async => const Success('bearer-token'));
      await service.login('a@b.com', 'pw');
      verify(() => sdk.saveToken('bearer-token')).called(1);
    });

    test('W3.9：登录失败 → 不 saveToken', () async {
      when(() => apis.authApi.loginResult(any(), any()))
          .thenAnswer((_) async => const Failure(UnauthorizedError('bad')));
      await service.login('a@b.com', 'pw');
      verifyNever(() => sdk.saveToken(any()));
    });

    test('W3.9：saveToken 抛异常 → 仍返 XbSuccess（Property 1 永不抛）', () async {
      when(() => apis.authApi.loginResult(any(), any()))
          .thenAnswer((_) async => const Success('t'));
      when(() => sdk.saveToken(any())).thenThrow(Exception('storage fail'));
      final r = await service.login('a@b.com', 'pw');
      expect(r, isA<XbSuccess<String>>());
    });
  });

  group('_mapError 7 子类映射（经 login Failure 驱动）', () {
    Future<XbDomainError> mapVia(SdkError e) async {
      when(() => apis.authApi.loginResult(any(), any()))
          .thenAnswer((_) async => Failure(e));
      final r = await service.login('a@b.com', 'pw');
      return (r as XbFailure).error;
    }

    test('UnauthorizedError → XbUnauthorized', () async {
      expect(await mapVia(const UnauthorizedError('m')), isA<XbUnauthorized>());
    });
    test('RateLimitError → XbRateLimit(kind, minutes)', () async {
      final e = await mapVia(
          const RateLimitError('m', kind: RateLimitKind.login, retryAfterMinutes: 5));
      expect(e, isA<XbRateLimit>());
      expect((e as XbRateLimit).retryAfterMinutes, 5);
      expect(e.kind, RateLimitKind.login);
    });
    test('BusinessError → XbBusiness(kind, validationErrors)（不持 httpStatusCode）', () async {
      final e = await mapVia(const BusinessError('m',
          httpStatusCode: 422,
          kind: BusinessErrorKind.validationFailed,
          validationErrors: {'email': ['invalid']}));
      expect(e, isA<XbBusiness>());
      expect((e as XbBusiness).kind, BusinessErrorKind.validationFailed);
      expect(e.validationErrors, {'email': ['invalid']});
    });
    test('NetworkError → XbNetwork(kind)', () async {
      final e = await mapVia(const NetworkError('m', kind: NetworkErrorKind.timeout));
      expect((e as XbNetwork).kind, NetworkErrorKind.timeout);
    });
    test('ServerError → XbServer(status)', () async {
      final e = await mapVia(const ServerError('m', httpStatusCode: 503));
      expect((e as XbServer).httpStatusCode, 503);
    });
    test('SecurityError → XbSecurity', () async {
      expect(await mapVia(const SecurityError('m')), isA<XbSecurity>());
    });
    test('UnexpectedError → XbUnexpected(operation)', () async {
      final e = await mapVia(UnexpectedError('m',
          cause: 'x', stackTrace: StackTrace.empty, operation: 'op'));
      expect((e as XbUnexpected).operation, 'op');
    });
  });

  group('getSubscription（throw 形态归一）', () {
    test('正常 → XbSuccess + R6.8 usedBytes = u + d', () async {
      when(() => apis.subscriptionApi.getSubscription()).thenAnswer((_) async =>
          const SubscriptionModel(
              email: 'a@b.com', uuid: 'uid', u: 100, d: 200, transferEnable: 1000));
      final r = await service.getSubscription();
      expect(r, isA<XbSuccess>());
      final sub = (r as XbSuccess).data;
      expect(sub.usedBytes, 300); // u + d
      expect(sub.totalBytes, 1000);
      expect(sub.remainingBytes, 700);
    });

    test('抛 AuthException → XbFailure(XbUnauthorized)（永不抛）', () async {
      when(() => apis.subscriptionApi.getSubscription())
          .thenThrow(AuthException('过期'));
      final r = await service.getSubscription();
      expect((r as XbFailure).error, isA<XbUnauthorized>());
    });

    test('抛任意 Object（θ-11 broad catch）→ XbUnexpected，不闪退', () async {
      when(() => apis.subscriptionApi.getSubscription())
          .thenThrow(TypeError());
      final r = await service.getSubscription();
      expect((r as XbFailure).error, isA<XbUnexpected>());
    });
  });

  group('未填实方法', () {
    test('fireAllMirrors void 不抛（Property 1 例外）', () {
      expect(() => service.fireAllMirrors(['https://m1', 'https://m2']),
          returnsNormally);
    });
  });

  group('W3 反腐层认证方法填实', () {
    test('register（SdkResult）+ D69 email 预处理', () async {
      when(() => apis.authApi.registerResult(any(), any(),
              emailCode: any(named: 'emailCode'),
              inviteCode: any(named: 'inviteCode')))
          .thenAnswer((_) async => const Success(true));
      final r = await service.register('  A@B.com ', 'pw', emailCode: '123456');
      expect((r as XbSuccess).data, isTrue);
      verify(() => apis.authApi.registerResult('a@b.com', 'pw',
          emailCode: '123456', inviteCode: null)).called(1);
    });

    test('sendEmailVerifyCode 限流 → XbBusiness(emailVerifyCodeRateLimit)', () async {
      when(() => apis.authApi.sendEmailVerifyCodeResult(any())).thenAnswer(
        (_) async => const Failure(BusinessError('rate',
            httpStatusCode: 400, kind: BusinessErrorKind.emailVerifyCodeRateLimit)),
      );
      final r = await service.sendEmailVerifyCode('a@b.com');
      final e = (r as XbFailure).error as XbBusiness;
      expect(e.kind, BusinessErrorKind.emailVerifyCodeRateLimit);
    });

    test('forgotPassword（throw 形态）成功 → XbSuccess(true)', () async {
      when(() => apis.authApi.forgotPassword(any(), any(), any()))
          .thenAnswer((_) async => true);
      final r = await service.forgotPassword('a@b.com', '123456', 'newpw');
      expect((r as XbSuccess).data, isTrue);
    });

    test('checkLogin → XbCheckLogin(isLogin)', () async {
      when(() => apis.userApi.checkLogin())
          .thenAnswer((_) async => const CheckLoginResult(isLogin: true));
      final r = await service.checkLogin();
      expect((r as XbSuccess).data.isLogin, isTrue);
    });

    test('getSubscribeUrl → XbSuccess(url)', () async {
      when(() => apis.subscriptionApi.getSubscribeUrl())
          .thenAnswer((_) async => 'https://h/sub/tok');
      final r = await service.getSubscribeUrl();
      expect((r as XbSuccess).data, 'https://h/sub/tok');
    });

    test('logout：服务端撤销 + 永不抛（即便 SDK logout 抛）', () async {
      when(() => sdk.auth).thenReturn(apis.authApi);
      when(() => apis.authApi.logout()).thenThrow(Exception('server down'));
      final r = await service.logout();
      expect(r, isA<XbSuccess<void>>()); // θ-2：服务端失败不阻塞本地
    });
  });
}
