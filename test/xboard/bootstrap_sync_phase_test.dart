/// W1.5.10 — XboardModule.bootstrap 同步阶段单测（DD-17 render-first，零网络）。
///
/// 注入 fake XBoardSDK + fake TokenStorage，验证 step 0-8 关键效果：
/// - SDK initialize 被调（用本地 endpoint）
/// - 写 apiEndpoint / subscriptionEndpoint / xboardSdk / bootstrapReady provider
/// - bootstrapReady 切 true（fallback 兜底）
/// - firstLaunch：无 token → true
/// - bootstrap 永不抛（SDK initialize 抛异常时 bootstrapReady 保持 false）

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/xboard_module.dart';

import '../_fixtures/fake_token_storage.dart';
import '../_fixtures/fake_xboard_sdk.dart';

void main() {
  late ProviderContainer container;
  late FakeXBoardSDK sdk;

  setUpAll(() {
    registerFallbackValue(_FakeTokenStorageFallback());
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({}); // W4.6 firstLaunch 读 consent key
    container = ProviderContainer();
    sdk = FakeXBoardSDK();
    // initialize 默认成功（具名参，用 any/named 宽松匹配）。
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
  });

  tearDown(() {
    container.dispose();
    XboardConfig.resetForTest();
  });

  test('同步阶段成功：写 4 provider + bootstrapReady=true', () async {
    final storage = FakeTokenStorage(); // 无 token

    await XboardModule.bootstrap(container, tokenStorage: storage, sdk: sdk);

    expect(container.read(bootstrapReadyProvider), isTrue);
    expect(container.read(apiEndpointProvider), XboardConfig.current.devApiEndpoint);
    expect(container.read(subscriptionEndpointProvider),
        XboardConfig.current.devSubscriptionEndpoint);
    expect(container.read(xboardSdkProvider), same(sdk));
  });

  test('SDK initialize 用本地 endpoint 作 baseUrl（位置参）', () async {
    final storage = FakeTokenStorage();

    await XboardModule.bootstrap(container, tokenStorage: storage, sdk: sdk);

    final captured = verify(() => sdk.initialize(
          captureAny(),
          panelType: any(named: 'panelType'),
          customStorage: any(named: 'customStorage'),
          proxyUrl: any(named: 'proxyUrl'),
          userAgent: any(named: 'userAgent'),
          httpConfig: any(named: 'httpConfig'),
          useMemoryStorage: any(named: 'useMemoryStorage'),
          enableLogging: any(named: 'enableLogging'),
          usePrintLogger: any(named: 'usePrintLogger'),
          allowNonFlclashUa: any(named: 'allowNonFlclashUa'),
        )).captured;
    expect(captured.single, XboardConfig.current.devApiEndpoint);
  });

  test('step 0 firstLaunch：无 token + 无 consent → true', () async {
    final storage = FakeTokenStorage(); // 无 token
    await XboardModule.bootstrap(container, tokenStorage: storage, sdk: sdk);
    expect(container.read(firstLaunchProvider), isTrue);
  });

  test('step 0 firstLaunch：有 token → 保持 false', () async {
    final storage = FakeTokenStorage(initialToken: 'raw-token');
    await XboardModule.bootstrap(container, tokenStorage: storage, sdk: sdk);
    expect(container.read(firstLaunchProvider), isFalse);
  });

  test('step 0 firstLaunch：无 token 但已 consent → 保持 false（W4.6 § J）', () async {
    SharedPreferences.setMockInitialValues({'xb_consent_v1': true});
    final storage = FakeTokenStorage(); // 无 token
    await XboardModule.bootstrap(container, tokenStorage: storage, sdk: sdk);
    expect(container.read(firstLaunchProvider), isFalse); // 用过 → 非首次
  });

  test('SDK initialize 抛异常 → bootstrap 不抛 + bootstrapReady 保持 false', () async {
    final storage = FakeTokenStorage();
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
        )).thenThrow(StateError('boom'));

    // 不抛（DD-2）
    await XboardModule.bootstrap(container, tokenStorage: storage, sdk: sdk);
    expect(container.read(bootstrapReadyProvider), isFalse);
  });
}

/// mocktail registerFallbackValue 用占位（customStorage: any(named:) 需要）。
class _FakeTokenStorageFallback extends Fake implements TokenStorage {}
