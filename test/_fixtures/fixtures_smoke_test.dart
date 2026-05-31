/// W0.3.8 冒烟测试 —— 仅验证 4 个 fake 可实例化 + 场景预设桩生效。
///
/// 无业务逻辑断言（业务断言在各 R 模块测试里），只保证 fixture 自身编译 + 基本可用。
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';

import 'fake_connectivity.dart';
import 'fake_secure_storage.dart';
import 'fake_token_storage.dart';
import 'fake_xboard_sdk.dart';

void main() {
  group('FakeXBoardSDK', () {
    test('实例化 + 11 sub-API getter 桩生效（loggedIn）', () {
      final sdk = FakeXBoardSDK();
      final apis = sdk.setupFor(XbScenario.loggedIn);

      expect(sdk.isInitialized, isTrue);
      expect(sdk.isAuthenticated, isTrue);
      expect(sdk.authState, AuthState.authenticated);
      // 11 个 sub-API getter 全回 fake 实例（同一引用）
      expect(sdk.auth, same(apis.authApi));
      expect(sdk.user, same(apis.userApi));
      expect(sdk.plan, same(apis.planApi));
      expect(sdk.order, same(apis.orderApi));
      expect(sdk.subscription, same(apis.subscriptionApi));
      expect(sdk.invite, same(apis.inviteApi));
      expect(sdk.ipMirror, same(apis.ipMirrorApi));
      expect(sdk.notice, same(apis.noticeApi));
      expect(sdk.ticket, same(apis.ticketApi));
      expect(sdk.config, same(apis.configApi));
      expect(sdk.payment, same(apis.paymentApi));
    });

    test('loggedOut / firstLaunch 场景 = 未认证', () async {
      for (final s in [XbScenario.loggedOut, XbScenario.firstLaunch]) {
        final sdk = FakeXBoardSDK()..setupFor(s);
        expect(sdk.isAuthenticated, isFalse, reason: '$s');
        expect(sdk.authState, AuthState.unauthenticated, reason: '$s');
        expect(await sdk.getToken(), isNull, reason: '$s');
      }
    });

    test('tokenExpired 场景 = 有 token 但本地态未认证', () async {
      final sdk = FakeXBoardSDK()..setupFor(XbScenario.tokenExpired);
      expect(sdk.isAuthenticated, isFalse);
      expect(await sdk.getToken(), 'Bearer expired-token');
      expect(await sdk.hasToken(), isTrue);
    });
  });

  group('FakeTokenStorage', () {
    test('raw token 读写删 round-trip', () async {
      final storage = FakeTokenStorage();
      await storage.ready;
      expect(await storage.readToken(), isNull);
      expect(storage.hasToken, isFalse);

      await storage.writeToken('raw-token-123');
      expect(await storage.readToken(), 'raw-token-123');
      expect(storage.hasToken, isTrue);

      await storage.deleteToken();
      expect(await storage.readToken(), isNull);
    });

    test('initialToken 构造', () async {
      final storage = FakeTokenStorage(initialToken: 'seed');
      expect(await storage.readToken(), 'seed');
    });
  });

  group('FakeSecureStorage', () {
    test('正常内存模式 read/write/delete/deleteAll', () async {
      final s = FakeSecureStorage();
      await s.write(key: 'k', value: 'v');
      expect(await s.read(key: 'k'), 'v');
      expect(await s.containsKey(key: 'k'), isTrue);
      expect(s.length, 1);

      await s.delete(key: 'k');
      expect(await s.read(key: 'k'), isNull);

      await s.write(key: 'a', value: '1');
      await s.write(key: 'b', value: '2');
      await s.deleteAll();
      expect(s.length, 0);
    });

    test('write(value:null) 删除 key', () async {
      final s = FakeSecureStorage();
      await s.write(key: 'k', value: 'v');
      await s.write(key: 'k', value: null);
      expect(await s.read(key: 'k'), isNull);
    });

    test('simulateLinuxFailure 抛 PlatformException（ζ1 降级路径）', () async {
      final s = FakeSecureStorage(simulateLinuxFailure: true);
      expect(() => s.read(key: 'k'), throwsA(isA<PlatformException>()));
      expect(
        () => s.write(key: 'k', value: 'v'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('FakeConnectivity', () {
    test('初始态 + emit 推送网络变化', () async {
      final conn = FakeConnectivity();
      expect(await conn.checkConnectivity(), [ConnectivityResult.wifi]);

      final events = <List<ConnectivityResult>>[];
      final sub = conn.onConnectivityChanged.listen(events.add);

      conn.goOffline();
      conn.goMobile();
      await Future<void>.delayed(Duration.zero); // 让 broadcast 派发

      expect(events, [
        [ConnectivityResult.none],
        [ConnectivityResult.mobile],
      ]);
      expect(await conn.checkConnectivity(), [ConnectivityResult.mobile]);

      await sub.cancel();
      await conn.close();
    });
  });
}
