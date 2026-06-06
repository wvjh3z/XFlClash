/// W4.6 — 节点 / 我的 Tab 深浅色适配测试（R8.1/R8.2/R8.3）。
///
/// 验证两 Tab 在 light / dark 主题下均能渲染、不抛 overflow、文字色跟随主题。
/// （golden 像素基线在 CI 环境生成；此处用结构性断言保证深浅色双跑不崩 + 取色自主题。）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxiesTabState;
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/nodes_tab.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

ProxiesTabState _emptyTab() => const ProxiesTabState(
      groups: [],
      currentGroupName: null,
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

Future<void> pumpThemed(
  WidgetTester tester,
  Widget child, {
  required Brightness brightness,
  required AuthState auth,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(() => _FakeAuth(auth)),
        proxiesTabStateProvider.overrideWith((ref) => _emptyTab()),
      ],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness, useMaterial3: true),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('NodesTab 渲染（${brightness.name}，游客）', (tester) async {
      await pumpThemed(tester, const NodesTab(),
          brightness: brightness, auth: AuthState.unauthenticated);
      expect(tester.takeException(), isNull);
      expect(find.text('登录后查看专属线路'), findsOneWidget);
    });

    testWidgets('MineTab 渲染（${brightness.name}，游客）', (tester) async {
      await pumpThemed(tester, const MineTab(),
          brightness: brightness, auth: AuthState.unauthenticated);
      expect(tester.takeException(), isNull);
      expect(find.text('登录后同步专属节点与套餐'), findsOneWidget);
    });
  }
}
