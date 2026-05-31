/// W5.5.7 / Property 8 — seam #7 globalUa 强制注入（F221 / DD-12）。
///
/// bootstrap 后（initProvider==true）`patchClashConfigProvider.globalUa` 一定含单一 `flclash` 子串。

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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
        )).thenAnswer((_) async {});
  });

  tearDown(() async {
    await XboardModule.dispose();
    XboardConfig.resetForTest();
  });

  bool hasSingleFlclash(String? ua) {
    if (ua == null) return false;
    final lower = ua.toLowerCase();
    var count = 0, idx = 0;
    while (true) {
      final f = lower.indexOf('flclash', idx);
      if (f == -1) break;
      count++;
      idx = f + 'flclash'.length;
    }
    return count == 1;
  }

  test('Property 8：initProvider==true 时 bootstrap 注入 globalUa（单一 flclash）', () async {
    final container = ProviderContainer(overrides: [
      initProvider.overrideWithBuild((ref, notifier) => true), // attach 已完成
    ]);
    addTearDown(container.dispose);
    // 保活 patchClashConfigProvider（autoDispose），避免 update 后被回收丢失。
    container.listen(patchClashConfigProvider, (_, __) {});

    await XboardModule.bootstrap(container,
        tokenStorage: FakeTokenStorage(), sdk: sdk);

    final ua = container.read(patchClashConfigProvider).globalUa;
    expect(ua, XboardConfig.current.subscribeUserAgent);
    expect(hasSingleFlclash(ua), isTrue, reason: 'globalUa 必须含且仅含一个 flclash 子串');
  });

  test('默认 subscribeUserAgent 含且仅含一个 flclash（F202/F203）', () {
    expect(hasSingleFlclash(XboardConfig.current.subscribeUserAgent), isTrue);
  });
}
