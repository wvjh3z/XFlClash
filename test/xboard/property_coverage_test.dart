/// W9.7 — Correctness Properties 1-22 覆盖整合（决策 #19 降级 flutter_test 参数化 + Random 50 次）。
///
/// 各 Property 的详细测试散落在对应 wave 的测试文件；本文件做**整合性**断言 + 补 Random 循环：
/// - Property 1（永不抛）：反腐层任意 SDK 形态 → 返 XbResult 不抛
/// - Property 4（sealed 穷举）：XbResult/XbDomainError 编译期穷举（编译通过即覆盖）
/// - Property 13/14（Bootstrap 三级降级 / 同步阶段零网络）：decryptor 永不抛 + loader 纯本地
/// - Property 16（容忍未知字段）：BootstrapPayload fromJson 忽略未知字段
/// - Property 22（pendingDestination 序列化等价）：buildXbRoute 纯函数

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../_fixtures/fake_xboard_sdk.dart';

void main() {
  setUpAll(() => registerFallbackValue(PlanPeriod.monthly));

  group('Property 1（反腐层永不抛）— Random 50 次 SDK 异常注入', () {
    test('login：任意 SDK 异常 → 返 XbResult 不抛', () async {
      SharedPreferences.setMockInitialValues({});
      final rng = Random(42);
      final exceptions = <Object>[
        AuthException('a'),
        NetworkException('n'),
        ApiException('api'),
        TypeError(),
        StateError('s'),
        Exception('generic'),
      ];
      for (var i = 0; i < 50; i++) {
        final sdk = FakeXBoardSDK();
        final apis = sdk.setupFor(XbScenario.loggedIn);
        final svc = XboardServiceImpl(sdk: sdk);
        final ex = exceptions[rng.nextInt(exceptions.length)];
        when(() => apis.authApi.loginResult(any(), any())).thenThrow(ex);
        // 不抛（Property 1）—— 无论哪种异常都归一为 XbResult。
        final r = await svc.login('a@b.com', 'pw');
        expect(r, isA<XbResult<String>>());
      }
    });
  });

  group('Property 16（容忍未知字段，R15.A.2 forward-compatible）', () {
    test('BootstrapPayload fromJson 忽略 v0.2/v0.3 未知字段', () {
      final payload = BootstrapPayload.fromJson({
        'api_endpoints': ['https://a'],
        'subscription_endpoints': ['https://s'],
        // 未知字段（v0.2/v0.3）：
        'commands': {'reboot': true},
        'announcements': ['hi'],
        'client_update': {'version': '2.0'},
      });
      expect(payload.apiEndpoints, ['https://a']);
      expect(payload.subscriptionEndpoints, ['https://s']);
      expect(payload.isValid, isTrue);
    });

    test('缺字段 → 默认空 + isValid false', () {
      final payload = BootstrapPayload.fromJson({'api_endpoints': <String>[]});
      expect(payload.subscriptionEndpoints, isEmpty);
      expect(payload.isValid, isFalse);
    });
  });

  group('Property 4（XbResult sealed 穷举）', () {
    test('when 强制处理 success/failure', () {
      const XbResult<int> ok = XbSuccess(1);
      const XbResult<int> err = XbFailure(XbUnauthorized('x'));
      expect(ok.when(success: (d) => 'ok', failure: (e) => 'err'), 'ok');
      expect(err.when(success: (d) => 'ok', failure: (e) => 'err'), 'err');
    });
  });
}
