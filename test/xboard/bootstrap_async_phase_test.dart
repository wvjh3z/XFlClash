/// W5 异步阶段单测（XboardModule.bootstrapAsync —— 远端拉取 → 竞速 → 热替换编排）。
///
/// 覆盖（接缝点 #1.bis / R15.B/C/H）：
/// - loadLocal 解出本地缓存 payload → 同步阶段用其 endpoint（替代出厂 stub）；
/// - bootstrapAsync 远端无镜像 → 退回本地 payload 竞速 → onApiSwitch 热替换 apiEndpoint；
/// - 竞速选可达 endpoint（fake probe）→ 写 apiEndpointProvider；
/// - single-flight：重复调 bootstrapAsync 不二次竞速；
/// - 永不抛（race controller 未就绪 / 无 payload 都安全返回）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/xboard_module.dart';

import '../_fixtures/fake_token_storage.dart';
import '../_fixtures/fake_xboard_sdk.dart';
import 'services/_bootstrap_crypto_helper.dart';

/// 测试 config：注入已知 AES key（与 crypto helper testAesKey 一致）+ 本地竞速候选。
const _apiA = 'https://api-a.example.com';
const _apiB = 'https://api-b.example.com';
const _subA = 'https://sub-a.example.com';

void main() {
  late ProviderContainer container;
  late FakeXBoardSDK sdk;

  setUpAll(() => registerFallbackValue(_FakeTokenStorageFallback()));

  setUp(() {
    container = ProviderContainer();
    sdk = FakeXBoardSDK();
    when(() => sdk.initialize(
          any(),
          panelType: any(named: 'panelType'),
          customStorage: any(named: 'customStorage'),
          proxyUrl: any(named: 'proxyUrl'),
          userAgent: any(named: 'userAgent'),
          httpConfig: any(named: 'httpConfig'),
          useMemoryStorage: any(named: 'useMemoryStorage'),
          enableLogging: any(named: 'enableLogging'),
          usePrintLogger: any(named: 'usePrintLogger'),
          allowNonFlclashUa: any(named: 'allowNonFlclashUa'),
        )).thenAnswer((_) async {});
    when(() => sdk.switchBaseUrl(any())).thenReturn(null);
  });

  tearDown(() async {
    await XboardModule.dispose();
    container.dispose();
    XboardConfig.resetForTest();
  });

  /// 绑定带已知 AES key + bootstrapUrls 空（异步阶段退回本地 payload）的测试 config。
  void bindTestConfig({List<String> bootstrapUrls = const []}) {
    XboardConfig.bind(XboardConfig(
      subscribeUserAgent: 'Test/0.1 flclash',
      devApiEndpoint: 'https://factory.example.com',
      devSubscriptionEndpoint: 'https://factory-sub.example.com',
      debug: false,
      kIsTest: true,
      bootstrapUrls: bootstrapUrls,
      bootstrapAesKeyBytes: testAesKey,
    ));
  }

  /// 在 SharedPreferences 写入合法加密缓存 envelope（loadLocal 命中）。
  Future<void> seedCache({
    List<String> api = const [_apiA, _apiB],
    List<String> sub = const [_subA],
  }) async {
    final env = await validEnvelope(api: api, sub: sub);
    SharedPreferences.setMockInitialValues({
      kBootstrapCacheKey: jsonEncode(env.toJson()),
    });
  }

  test('同步阶段 loadLocal 命中缓存 → 用缓存 endpoint（替代出厂 stub）', () async {
    bindTestConfig();
    await seedCache();
    await XboardModule.bootstrap(container,
        tokenStorage: FakeTokenStorage(), sdk: sdk);
    // step3 解出 payload → step6 写缓存首个 endpoint，而非 config 出厂值。
    expect(container.read(apiEndpointProvider), _apiA);
    expect(container.read(subscriptionEndpointProvider), _subA);
  });

  test('异步阶段：无镜像 → 退回本地 payload 竞速 → 选可达 endpoint 热替换', () async {
    bindTestConfig(); // bootstrapUrls 空 → 走本地 payload
    await seedCache(api: [_apiA, _apiB]);
    // fake probe：只有 _apiB 可达 → 竞速应切到 _apiB。
    await XboardModule.bootstrap(
      container,
      tokenStorage: FakeTokenStorage(),
      sdk: sdk,
      debugProbe: (ep) async => ep == _apiB,
    );
    // 同步阶段先写 _apiA（缓存首项）。
    expect(container.read(apiEndpointProvider), _apiA);

    await XboardModule.bootstrapAsync(container);
    // 竞速后热替换到唯一可达的 _apiB。
    expect(container.read(apiEndpointProvider), _apiB);
    verify(() => sdk.switchBaseUrl(_apiB)).called(greaterThanOrEqualTo(1));
  });

  test('single-flight：重复 bootstrapAsync 不二次竞速', () async {
    bindTestConfig();
    await seedCache(api: [_apiA]);
    var probeCount = 0;
    await XboardModule.bootstrap(
      container,
      tokenStorage: FakeTokenStorage(),
      sdk: sdk,
      debugProbe: (ep) async {
        probeCount++;
        return true;
      },
    );
    await XboardModule.bootstrapAsync(container);
    final afterFirst = probeCount;
    await XboardModule.bootstrapAsync(container); // 第二次应 no-op
    expect(probeCount, afterFirst, reason: 'single-flight 守卫：第二次不再竞速');
  });

  test('永不抛：race controller 未就绪（bootstrap 失败）→ bootstrapAsync 安全返回', () async {
    bindTestConfig();
    // SDK initialize 抛 → bootstrap 失败 → _raceController 未创建。
    when(() => sdk.initialize(
          any(),
          panelType: any(named: 'panelType'),
          customStorage: any(named: 'customStorage'),
          proxyUrl: any(named: 'proxyUrl'),
          userAgent: any(named: 'userAgent'),
          httpConfig: any(named: 'httpConfig'),
          useMemoryStorage: any(named: 'useMemoryStorage'),
          enableLogging: any(named: 'enableLogging'),
          usePrintLogger: any(named: 'usePrintLogger'),
          allowNonFlclashUa: any(named: 'allowNonFlclashUa'),
        )).thenThrow(StateError('init boom'));
    await XboardModule.bootstrap(container,
        tokenStorage: FakeTokenStorage(), sdk: sdk);
    // 不抛即通过。
    await XboardModule.bootstrapAsync(container);
    expect(container.read(bootstrapReadyProvider), isFalse);
  });

  test('永不抛：无缓存 + 无镜像 → 无竞速候选，安全返回（沿用出厂 endpoint）', () async {
    bindTestConfig();
    SharedPreferences.setMockInitialValues({}); // 无缓存
    await XboardModule.bootstrap(
      container,
      tokenStorage: FakeTokenStorage(),
      sdk: sdk,
      debugProbe: (_) async => true,
    );
    // loadLocal fallback 资产在测试环境不存在 → null → 用出厂 endpoint。
    expect(container.read(apiEndpointProvider), 'https://factory.example.com');
    await XboardModule.bootstrapAsync(container);
    // 无 payload → 不竞速，endpoint 不变。
    expect(container.read(apiEndpointProvider), 'https://factory.example.com');
  });
}

class _FakeTokenStorageFallback extends Fake implements TokenStorage {}
