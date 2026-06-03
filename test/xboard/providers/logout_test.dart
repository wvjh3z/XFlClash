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

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fl_clash/xboard/data/xboard_database.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/encrypted_subscription_service.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';

import '../../_fixtures/fake_token_storage.dart';

class _MockService extends Mock implements XboardService {}

class _MockSdk extends Mock implements XBoardSDK {}

class _MockAuthApi extends Mock implements AuthApi {}

/// 内存 fake profile 端口（记录删除调用，验证 step 4）。
class _FakePort implements ProfileSyncPort {
  final Map<int, String> profiles = {};
  final List<int> deleted = [];

  @override
  Future<int> createAndPutProfile(
      {required String url, required String label}) async {
    profiles[999] = url;
    return 999;
  }

  @override
  Future<void> updateProfileUrl(
      {required int profileId, required String url}) async {}

  @override
  Future<int> putFileProfile({
    required int? profileId,
    required Uint8List yamlBytes,
    required String label,
  }) async {
    final id = profileId ?? 777;
    profiles[id] = 'file';
    return id;
  }

  @override
  Future<void> deleteProfile(int profileId) async {
    deleted.add(profileId);
    profiles.remove(profileId);
  }

  @override
  List<int> currentProfileIds() => profiles.keys.toList();
}

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

  group('logout step 4：删 file profile + 外挂索引（数据一致性 § B）', () {
    late _MockService service;
    late _FakePort port;
    late XboardDatabase db;
    late ProviderContainer c;
    const token = 'tokA';

    setUp(() async {
      service = _MockService();
      port = _FakePort();
      db = XboardDatabase(NativeDatabase.memory());
      when(() => service.logout())
          .thenAnswer((_) async => XbResult<void>.success(null));

      // 预置：当前用户 token=tokA 已同步出一个 profile（id=777）+ 索引。
      final hash = userIdHashFromToken(token);
      await port.putFileProfile(profileId: null, yamlBytes: Uint8List(0), label: '我的套餐');
      await db.putIndex(profileId: 777, flavorId: 'brandA', userIdHash: hash);

      final subService = XboardSubscriptionService(
        service: service,
        encrypted: EncryptedSubscriptionService(
            decryptor: BootstrapDecryptor(aesKey: null)),
        profilePort: port,
        db: db,
        tokenStorage: FakeTokenStorage(initialToken: token),
        flavorId: 'brandA',
      );

      c = ProviderContainer(overrides: [
        xboardServiceProvider.overrideWithValue(service),
        subscriptionServiceProvider.overrideWithValue(subService),
      ]);
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    test('logout → 删 profile 777 + 清索引 + 切 unauthenticated', () async {
      c.read(authStateProvider.notifier).markAuthenticated();

      await c.read(authStateProvider.notifier).logout();

      // step 4：profile 被删 + 索引清空。
      expect(port.deleted, contains(777));
      expect(await db.findProfileId(flavorId: 'brandA', userIdHash: userIdHashFromToken(token)),
          isNull);
      // step 5：反腐层 logout 调用。
      verify(() => service.logout()).called(1);
      // step 6：切未登录。
      expect(c.read(authStateProvider), AuthState.unauthenticated);
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
