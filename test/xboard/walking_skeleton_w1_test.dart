/// W1.8.4 — Walking Skeleton W1 阶段集成冒烟。
///
/// 验证 W0-W1 闭环（不含原生 build，Dart 侧）：
/// - bootstrap 同步阶段完成 → bootstrapReady=true（接缝点 #1 调用的入口）
/// - navigation.getItems() 注入后含 9 项（接缝点 #6）
/// - 点 Xboard 项进 XboardServiceHomePage stub（显示「我的服务」）
///
/// 注：真机 / 原生 build 冒烟（W1.8.3）需 Ninja/CXX/Rust toolchain，留 CI 环境验证；
/// 本测试覆盖 Dart 侧集成（seam #1 bootstrap 入口 + seam #6 注入 + stub 可达）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/common/navigation.dart';
import 'package:fl_clash/providers/state.dart' show isStartProvider;
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/navigation/xboard_navigation.dart';
import 'package:fl_clash/xboard/pages/xboard_service_home_page.dart';
import 'package:fl_clash/xboard/providers/xboard_connectivity_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/xboard_module.dart';

import '../_fixtures/fake_token_storage.dart';
import '../_fixtures/fake_xboard_sdk.dart';

class _FakeTokenStorageFallback extends Fake implements TokenStorage {}

void main() {
  setUpAll(() => registerFallbackValue(_FakeTokenStorageFallback()));
  setUp(() => SharedPreferences.setMockInitialValues({'xb_consent_v1': true}));
  tearDown(() async {
    await XboardModule.dispose(); // 关 R4.9 isStartProvider 监听 + observer，清挂起 timer
    XboardConfig.resetForTest();
  });

  testWidgets('W1 walking skeleton：bootstrap + 9 项导航 + 点击进 stub', (tester) async {
    // 1. bootstrap 同步阶段（接缝点 #1 调用的入口）
    final container = ProviderContainer(overrides: [
      // 覆盖真实 connectivity 流（test 无平台插件，避免 onConnectivityChanged 挂起）。
      isOfflineProvider.overrideWith((ref) => false),
      // R4.9：覆盖 isStartProvider（VPN 开关）+ keepAlive，避免读 FlClash autoDispose
      // provider 触发 riverpod 调度器留挂起 dispose timer（testWidgets !timersPending 断言）。
      isStartProvider.overrideWith((ref) {
        ref.keepAlive();
        return false;
      }),
    ]);
    addTearDown(container.dispose);
    final sdk = FakeXBoardSDK();
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

    await XboardModule.bootstrap(container,
        tokenStorage: FakeTokenStorage(), sdk: sdk);
    expect(container.read(bootstrapReadyProvider), isTrue,
        reason: 'bootstrap 同步阶段应完成');

    // 2. 接缝点 #6：navigation 注入后 9 项
    final items = navigation.getItems(openLogs: true, hasProxies: true);
    expect(items, hasLength(9));
    final xboardItem = items.lastWhere(XboardNavigation.isXboardItem);

    // 3. 点 Xboard 项 → 进 stub 页（显示「我的服务」）
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Builder(builder: xboardItem.builder)),
      ),
    );
    expect(find.text('我的服务'), findsOneWidget);
    expect(find.byType(XboardServiceHomePage), findsOneWidget);
  });
}
