/// W3.6.8 — R4.5 logout 编排 + idempotency 测试矩阵（数据一致性总章 § B）。
///
/// 覆盖：
/// - 正常 logout → authState 切 unauthenticated + 调反腐层 logout
/// - 反腐层 logout 失败（返 XbFailure）→ 仍切 unauthenticated（永不卡中间态）
/// - 重入 logout（连点登出）→ idempotent，service.logout 各自调用，终态 unauthenticated
/// - logout 数据层（service impl）：step 0 服务端撤销 + step 5 clearToken；
///   SDK logout 抛异常 / clearToken 抛异常 → 仍返 XbSuccess（Property 1 永不抛）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' hide AuthState;
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';

class _MockService extends Mock implements XboardService {}

class _MockSdk extends Mock implements XBoardSDK {}

class _MockAuthApi extends Mock implements AuthApi {}

void main() {
  group('AuthStateNotifier.logout 编排（step 6）', () {
    late _MockService service;
    late ProviderContainer c;

    setUp(() {
      service = _MockService();
      c = ProviderContainer(
        overrides: [xboardServiceProvider.overrideWithValue(service)],
      );
    });
    tearDown(() => c.dispose());

    test('正常 logout → 切 unauthenticated + 调反腐层 logout', () async {
      when(() => service.logout())
          .thenAnswer((_) async => XbResult<void>.success(null));
      c.read(authStateProvider.notifier).markAuthenticated();

      await c.read(authStateProvider.notifier).logout();

      expect(c.read(authStateProvider), AuthState.unauthenticated);
      verify(() => service.logout()).called(1);
    });

    test('反腐层 logout 失败 → 仍切 unauthenticated（不卡中间态）', () async {
      when(() => service.logout()).thenAnswer(
          (_) async => XbResult<void>.failure(XbDomainError.unexpected('logout', 'boom')));
      c.read(authStateProvider.notifier).markAuthenticated();

      await c.read(authStateProvider.notifier).logout();

      expect(c.read(authStateProvider), AuthState.unauthenticated);
    });

    test('重入 logout（连点）→ idempotent，终态 unauthenticated', () async {
      when(() => service.logout())
          .thenAnswer((_) async => XbResult<void>.success(null));
      c.read(authStateProvider.notifier).markAuthenticated();

      await Future.wait([
        c.read(authStateProvider.notifier).logout(),
        c.read(authStateProvider.notifier).logout(),
      ]);

      expect(c.read(authStateProvider), AuthState.unauthenticated);
      verify(() => service.logout()).called(2); // 各自调用，service 侧 _isLoggingOut 幂等
    });
  });

  group('XboardServiceImpl.logout 数据层（step 0 + step 5，Property 1 永不抛）', () {
    late _MockSdk sdk;
    late _MockAuthApi auth;

    setUp(() {
      sdk = _MockSdk();
      auth = _MockAuthApi();
      when(() => sdk.auth).thenReturn(auth);
    });

    test('正常：调 auth.logout + clearToken → XbSuccess', () async {
      when(() => auth.logout()).thenAnswer((_) async => true);
      when(() => sdk.clearToken()).thenAnswer((_) async {});
      final impl = XboardServiceImpl(sdk: sdk);

      final r = await impl.logout();

      expect(r.isSuccess, isTrue);
      verify(() => auth.logout()).called(1);
      verify(() => sdk.clearToken()).called(1);
    });

    test('step 0 服务端 logout 抛异常 → 仍 clearToken + XbSuccess', () async {
      when(() => auth.logout()).thenThrow(Exception('server down'));
      when(() => sdk.clearToken()).thenAnswer((_) async {});
      final impl = XboardServiceImpl(sdk: sdk);

      final r = await impl.logout();

      expect(r.isSuccess, isTrue); // 不阻塞本地清理
      verify(() => sdk.clearToken()).called(1); // step 5 仍执行
    });

    test('step 5 clearToken 抛异常 → 仍 XbSuccess（永不抛 Property 1）', () async {
      when(() => auth.logout()).thenAnswer((_) async => true);
      when(() => sdk.clearToken()).thenThrow(Exception('storage error'));
      final impl = XboardServiceImpl(sdk: sdk);

      final r = await impl.logout();

      expect(r.isSuccess, isTrue);
    });
  });
}
