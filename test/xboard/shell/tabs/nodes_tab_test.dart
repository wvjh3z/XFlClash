/// W4.1·W4.2 — NodesTab 单测（游客 / 空态；populated 留 W6.4 集成冒烟）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxiesTabState;
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
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

Future<void> pumpNodes(
  WidgetTester tester, {
  required AuthState auth,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(() => _FakeAuth(auth)),
        proxiesTabStateProvider.overrideWith((ref) => _emptyTab()),
      ],
      child: const MaterialApp(home: Scaffold(body: NodesTab())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('游客态 → 登录引导（R4.7）', (tester) async {
    await pumpNodes(tester, auth: AuthState.unauthenticated);
    expect(find.text('登录后查看专属线路'), findsOneWidget);
    expect(find.text('登录 / 注册'), findsOneWidget);
  });

  testWidgets('已登录 + 无分组 → 空态引导续费（R4.6）', (tester) async {
    await pumpNodes(tester, auth: AuthState.authenticated);
    expect(find.text('暂无可用线路'), findsOneWidget);
    expect(find.text('查看套餐'), findsOneWidget);
    // 空态不显示搜索/分组标签（R4.6）。
    expect(find.text('刷新'), findsNothing);
  });
}
