/// W1.1（+ W3/W4 接入后）— XboardAppShell 三 Tab 外壳 widget test。
///
/// 覆盖：默认渲染首页 / 底栏三项 / 切 Tab 生效 / IndexedStack 保活。
/// 真实 HomeTab/NodesTab/MineTab 接入后，需补 FlClash + auth provider override（真 app 由
/// bootstrap 容器提供）；否则子树读 FlClash app-state provider（path_provider/DB）会抛。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
            proxyCardType: ProxyCardType.expand,
            columns: 2,
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

  testWidgets('点击底栏切换到节点 Tab', (tester) async {
    final original = ErrorWidget.builder;
    final container = _container();
    addTearDown(container.dispose);
    await pump(tester, container);
    // 点底栏「节点」（用 XbBottomBar 内的，避开页面标题歧义）。
    await tester.tap(find.text('节点').last);
    await tester.pumpAndSettle();
    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 1);
    ErrorWidget.builder = original;
  });

  testWidgets('IndexedStack 保活：三 Tab 子树同时在树上', (tester) async {
    final original = ErrorWidget.builder;
    final container = _container();
    addTearDown(container.dispose);
    await pump(tester, container);
    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.children.length, 3);
    ErrorWidget.builder = original;
  });
}
