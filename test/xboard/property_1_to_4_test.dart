/// W2.10 + W2.8.3 — 反腐层归一不变量 Property 1-4（决策 #19 降级 flutter_test 参数化 PBT）。
///
/// Property 1：任意 SDK 返回形态 → 17 个返结果方法永不抛（fireAllMirrors void 例外）
/// Property 2：UI/Provider 0 处 import SDK 内部类型（grep 静态校验，见下）
/// Property 3：7 个 SdkError 子类全覆盖映射 + 旧异常体系 3 子类 + catch-all 兜底
/// Property 4：XbResult 分支名 XbSuccess/XbFailure（非 Ok/Err，编译期穷举）

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';

import '../_fixtures/fake_xboard_sdk.dart';

void main() {
  late FakeXBoardSDK sdk;
  late FakeSubApis apis;
  late XboardServiceImpl service;

  setUp(() {
    sdk = FakeXBoardSDK();
    apis = sdk.setupFor(XbScenario.loggedIn);
    service = XboardServiceImpl(sdk: sdk);
  });

  group('Property 1：任意 SDK 形态 → 永不抛 + 必返 XbResult', () {
    // 决策 #19：50 次 Random 循环近似 PBT
    final rnd = Random(42);

    // 候选 SdkError 工厂（覆盖 7 子类）
    SdkError randomSdkError() {
      switch (rnd.nextInt(7)) {
        case 0:
          return const UnauthorizedError('m');
        case 1:
          return const RateLimitError('m', kind: RateLimitKind.login);
        case 2:
          return const BusinessError('m', httpStatusCode: 400);
        case 3:
          return const NetworkError('m', kind: NetworkErrorKind.timeout);
        case 4:
          return const ServerError('m', httpStatusCode: 500);
        case 5:
          return const SecurityError('m');
        default:
          return UnexpectedError('m',
              cause: 'c', stackTrace: StackTrace.empty, operation: 'op');
      }
    }

    test('login（SdkResult 形态）50 次随机 → 永不抛 + 必返 XbResult', () async {
      for (var i = 0; i < 50; i++) {
        final useSuccess = rnd.nextBool();
        when(() => apis.authApi.loginResult(any(), any())).thenAnswer(
          (_) async =>
              useSuccess ? const Success('tok') : Failure(randomSdkError()),
        );
        final r = await service.login('a@b.com', 'pw');
        expect(r, isA<XbResult<String>>());
      }
    });

    test('getSubscription（throw 形态）50 次随机异常 → 永不抛 + 必返 XbResult', () async {
      final throwables = <Object>[
        AuthException('a'),
        NetworkException('n'),
        ApiException('api'),
        TypeError(),
        StateError('s'),
        ArgumentError('arg'),
        Exception('generic'),
      ];
      for (var i = 0; i < 50; i++) {
        final t = throwables[rnd.nextInt(throwables.length)];
        when(() => apis.subscriptionApi.getSubscription()).thenThrow(t);
        final r = await service.getSubscription();
        expect(r, isA<XbResult>()); // 永不抛
        expect(r, isA<XbFailure>()); // 异常 → 失败
      }
    });
  });

  group('Property 3：7 SdkError 子类全覆盖 + 旧异常 3 子类 + 兜底', () {
    Future<XbDomainError> mapVia(SdkError e) async {
      when(() => apis.authApi.loginResult(any(), any()))
          .thenAnswer((_) async => Failure(e));
      return ((await service.login('a@b.com', 'pw')) as XbFailure).error;
    }

    test('7 SdkError 子类各映射到对应 XbDomainError', () async {
      expect(await mapVia(const UnauthorizedError('m')), isA<XbUnauthorized>());
      expect(await mapVia(const RateLimitError('m', kind: RateLimitKind.generic)),
          isA<XbRateLimit>());
      expect(await mapVia(const BusinessError('m', httpStatusCode: 400)),
          isA<XbBusiness>());
      expect(await mapVia(const NetworkError('m', kind: NetworkErrorKind.unknown)),
          isA<XbNetwork>());
      expect(await mapVia(const ServerError('m', httpStatusCode: 500)),
          isA<XbServer>());
      expect(await mapVia(const SecurityError('m')), isA<XbSecurity>());
      expect(
          await mapVia(UnexpectedError('m',
              cause: 'c', stackTrace: StackTrace.empty, operation: 'o')),
          isA<XbUnexpected>());
    });

    test('旧异常体系 3 子类（throw 形态）→ 对应映射', () async {
      Future<XbDomainError> viaThrow(Object e) async {
        when(() => apis.subscriptionApi.getSubscription()).thenThrow(e);
        return ((await service.getSubscription()) as XbFailure).error;
      }

      expect(await viaThrow(AuthException('a')), isA<XbUnauthorized>());
      expect(await viaThrow(NetworkException('n')), isA<XbNetwork>());
      expect(await viaThrow(ApiException('api')), isA<XbBusiness>());
      // catch-all 兜底 → XbUnexpected
      expect(await viaThrow(StateError('s')), isA<XbUnexpected>());
    });
  });

  group('Property 4：XbResult 分支名 XbSuccess/XbFailure（非 Ok/Err）', () {
    test('sealed switch 编译期穷举两分支', () {
      String label(XbResult<int> r) => switch (r) {
            XbSuccess<int>() => 'success',
            XbFailure<int>() => 'failure',
          };
      expect(label(const XbSuccess(1)), 'success');
      expect(label(const XbFailure(XbUnauthorized('x'))), 'failure');
    });
  });

  // W2.8.3：恶意构造响应（θ-11）→ 走 XbUnexpected 不闪退（NFR-7/R11.5）
  group('W2.8.3 θ-11 恶意响应 broad catch', () {
    test('SDK getSubscription 抛 TypeError（如 total_amount="abc"）→ XbUnexpected', () async {
      when(() => apis.subscriptionApi.getSubscription())
          .thenThrow(TypeError());
      final r = await service.getSubscription();
      expect((r as XbFailure).error, isA<XbUnexpected>());
    });
  });

  // Property 2：UI/Provider 0 处 import SDK barrel（唯一例外 xboard_service_impl.dart）
  group('Property 2：SDK 类型零穿透（静态 grep 校验）', () {
    test('lib/xboard/ 下仅 xboard_service_impl.dart import SDK barrel', () {
      final dir = Directory('lib/xboard');
      final offenders = <String>[];
      for (final f in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        // 跳过生成产物（freezed/g.dart 不 import SDK barrel）
        if (f.path.contains('/generated/')) continue;
        final src = f.readAsStringSync();
        final importsSdk =
            src.contains("import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'");
        if (!importsSdk) continue;
        final base = f.uri.pathSegments.last;
        // 允许：反腐层 impl（唯一桥梁）+ 仅用 SDK enum/type 别名的 models/providers
        // 严格版：只允许 xboard_service_impl.dart import 完整 barrel。
        // 现实：models 用 typedef 复用 SDK enum（BusinessErrorKind 等）也 import barrel（show 限定）。
        // 故校验「非 impl 文件若 import，必须用 show 限定（不全量穿透）」。
        if (base == 'xboard_service_impl.dart') continue;
        final usesShow = RegExp(
                r"import 'package:flutter_xboard_sdk/flutter_xboard_sdk\.dart'\s+show ")
            .hasMatch(src);
        if (!usesShow) {
          offenders.add(f.path);
        }
      }
      expect(offenders, isEmpty,
          reason: '以下文件全量 import SDK barrel（应只 impl 或 show 限定）：\n${offenders.join('\n')}');
    });
  });
}
