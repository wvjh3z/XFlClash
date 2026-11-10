/// W1.1（+ W3/W4 接入后）— XboardAppShell 三 Tab 外壳 widget test。
///
/// 覆盖：默认渲染首页 / 底栏三项 / 切 Tab 生效 / IndexedStack 保活。
/// 真实 HomeTab/NodesTab/MineTab 接入后，需补 FlClash + auth provider override（真 app 由
/// bootstrap 容器提供）；否则子树读 FlClash app-state provider（path_provider/DB）会抛。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show AppUpdateModel;

import 'package:fl_clash/enum/enum.dart' show CoreStatus, ProxyCardType;
import 'package:fl_clash/models/models.dart' show PatchClashConfig, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import '_net_detection_stub.dart';
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';

class _Ready extends BootstrapReady {
  @override
  bool build() => true;
}

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

ProviderContainer _container() {
  final c = ProviderContainer(
    overrides: [
      bootstrapReadyProvider.overrideWith(() => _Ready()),
      authStateProvider.overrideWith(() => _Auth()),
      isStartProvider.overrideWith((ref) => false),
      proxiesTabStateProvider.overrideWith((ref) => const ProxiesTabState(
            groups: [],
            currentGroupName: null,
            proxyCardType: ProxyCardType.standard,

          )),
      patchClashConfigProvider
          .overrideWithBuild((ref, _) => const PatchClashConfig()),
      netDetectionOverride(),
    ],
  );
  c.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  return c;
}

void main() {
  testWidgets('withdrawn queued update does not open or consume future prompt', (tester) async {
    final original = ErrorWidget.builder;
    final container = _container();
    const update = AppUpdateModel(versionCode: 999, versionName: 'fixture',
        region: 'unknown', downloads: [], sha256: '', changelog: '', force: false);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: const MaterialApp(home: XboardAppShell())));
      await tester.pump();
      container.read(availableUpdateProvider.notifier).set(update);
      // The real shell listener has queued its post-frame presentation.
      container.read(availableUpdateProvider.notifier).clear();
      await tester.pumpAndSettle();
      expect(find.text('立即更新'), findsNothing);
      container.read(availableUpdateProvider.notifier).set(update);
      await tester.pumpAndSettle();
      expect(find.text('立即更新'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      ErrorWidget.builder = original;
    }
  });
  // XboardAppShell.initState 安装形态 A 友好 ErrorWidget.builder；
  // Flutter test 框架要求 body 结束前还原（tearDown 太晚），故每个 test body 末尾还原。
  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: XboardAppShell()),
      ),
    );
    await tester.pump();
  }

  testWidgets('默认渲染首页 Tab + 底栏三项', (tester) async {
    final original = ErrorWidget.builder;
    final container = _container();
    addTearDown(container.dispose);
    await pump(tester, container);
    // 底栏三项 label。
    expect(find.text('首页'), findsWidgets);
    expect(find.text('节点'), findsWidgets);
    expect(find.text('我的'), findsWidgets);
    // 默认 index=0 → 首页连接球的「未连接」可见（HomeTab 真实渲染）。
    expect(find.text('未连接'), findsOneWidget);
    ErrorWidget.builder = original;
  });

  testWidgets('点击底栏横滑切换到节点 Tab', (tester) async {
    final original = ErrorWidget.builder;
    final container = _container();
    addTearDown(container.dispose);
    await pump(tester, container);
    // 点底栏「节点」（用 XbBottomBar 内的，避开页面标题歧义）。
    await tester.tap(find.text('节点').last);
    await tester.pumpAndSettle();
    // 横滑落定 → 节点页内容（「选择线路」标题）可见。
    expect(find.text('选择线路'), findsOneWidget);
    ErrorWidget.builder = original;
  });

  testWidgets('PageView 保活：切到节点再切回首页，首页状态不丢', (tester) async {
    final original = ErrorWidget.builder;
    final container = _container();
    addTearDown(container.dispose);
    await pump(tester, container);
    expect(find.byType(PageView), findsOneWidget);
    // 切到节点。
    await tester.tap(find.text('节点').last);
    await tester.pumpAndSettle();
    // 切回首页 → 连接球仍在（keep-alive，未因重建丢状态）。
    await tester.tap(find.text('首页').last);
    await tester.pumpAndSettle();
    expect(find.text('未连接'), findsOneWidget);
    ErrorWidget.builder = original;
  });
}
