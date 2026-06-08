/// seam #7 — 「首次安装默认开 IPv6」（用户 2026-06-09 决策）。
///
/// 契约：
/// 1. 首次启动（无 kXbIpv6DefaultAppliedKey 标记）→ bootstrap 后 `patchClashConfig.ipv6 == true`
///    且标记落位。
/// 2. 已应用过（标记已在）→ bootstrap **不覆盖** ipv6（尊重用户后续修改，即便用户关成 false）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/providers/app.dart' show initProvider;
import 'package:fl_clash/providers/config.dart' show patchClashConfigProvider;
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/xboard_module.dart';

import '../_fixtures/fake_token_storage.dart';
import '../_fixtures/fake_xboard_sdk.dart';

class _FakeTokenStorageFallback extends Fake implements TokenStorage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(_FakeTokenStorageFallback()));

  late FakeXBoardSDK sdk;

  void stubInit() {
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
  }

  tearDown(() async {
    await XboardModule.dispose();
    XboardConfig.resetForTest();
  });

  /// 跑一次 bootstrap（initProvider 已 true → seam #7 立即执行），返回最终 ipv6 值。
  Future<bool> runBootstrapAndReadIpv6() async {
    final container = ProviderContainer(overrides: [
      initProvider.overrideWithBuild((ref, notifier) => true), // attach 已完成
    ]);
    addTearDown(container.dispose);
    // 保活 patchClashConfigProvider（autoDispose），避免 update 后被回收丢失。
    container.listen(patchClashConfigProvider, (_, _) {});

    await XboardModule.bootstrap(container,
        tokenStorage: FakeTokenStorage(), sdk: sdk);
    // seam #7 是 async（读/写 SharedPreferences），让微任务落定。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return container.read(patchClashConfigProvider).ipv6;
  }

  test('首次启动（无标记）→ ipv6 默认开 + 落标记', () async {
    SharedPreferences.setMockInitialValues({}); // 无标记
    sdk = FakeXBoardSDK();
    stubInit();

    final ipv6 = await runBootstrapAndReadIpv6();
    expect(ipv6, isTrue, reason: '首次安装默认开 IPv6');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kXbIpv6DefaultAppliedKey), isTrue, reason: '应用后落标记');
  });

  test('已应用过（标记在）+ 用户关成 false → 不被覆盖（尊重用户）', () async {
    // 模拟：已应用过默认 + 用户后来手动关了 ipv6。
    SharedPreferences.setMockInitialValues({kXbIpv6DefaultAppliedKey: true});
    sdk = FakeXBoardSDK();
    stubInit();

    final container = ProviderContainer(overrides: [
      initProvider.overrideWithBuild((ref, notifier) => true),
    ]);
    addTearDown(container.dispose);
    container.listen(patchClashConfigProvider, (_, _) {});
    // 用户已关 ipv6。
    container
        .read(patchClashConfigProvider.notifier)
        .update((s) => s.copyWith(ipv6: false));

    await XboardModule.bootstrap(container,
        tokenStorage: FakeTokenStorage(), sdk: sdk);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(patchClashConfigProvider).ipv6, isFalse,
        reason: '标记已在 → seam #7 跳过，尊重用户的关闭');
  });
}
