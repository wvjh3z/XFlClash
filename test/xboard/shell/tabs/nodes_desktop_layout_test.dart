/// C-分支桌面节点 master-detail 布局几何测试。
///
/// 宽窗口（1280×800）下断言 NodesTab 走 master-detail：左侧出现「线路分组」分组栏，
/// 右侧节点以双列网格并排（同一分组两节点 dy 相近、dx 不同，左节点在分组栏右侧）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxiesTabState, Group, Proxy;
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/nodes_tab.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

ProxiesTabState _twoNodeTab() => const ProxiesTabState(
      groups: [
        Group(
          type: GroupType.Selector,
          name: '香港',
          now: '港A',
          all: [
            Proxy(name: '港A', type: 'ss'),
            Proxy(name: '港B', type: 'vmess'),
          ],
        ),
        Group(
          type: GroupType.Selector,
          name: '日本',
          now: '日A',
          all: [Proxy(name: '日A', type: 'ss')],
        ),
      ],
      currentGroupName: '香港',
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

Future<void> pumpDesktopNodes(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final state = _twoNodeTab();
  final overrides = [
    authStateProvider.overrideWith(() => _FakeAuth(AuthState.authenticated)),
    proxiesTabStateProvider.overrideWith((ref) => state),
  ];
  for (final g in state.groups) {
    overrides.add(selectedProxyNameProvider(g.name).overrideWithValue(g.now));
    overrides.add(proxyNameProvider(g.name).overrideWithValue(null));
    for (final p in g.all) {
      overrides.add(
        delayProvider(proxyName: p.name, testUrl: g.testUrl)
            .overrideWithValue(48),
      );
    }
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: Scaffold(body: NodesTab())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('桌面：master-detail 左分组栏 + 右双列节点网格', (tester) async {
    await pumpDesktopNodes(tester);

    // 左侧分组栏标志「线路分组」（仅 master-detail 出现）。
    expect(find.text('线路分组'), findsOneWidget);

    // 选中「香港」组的两节点都在，双列并排。
    final aRect = tester.getRect(find.text('港A'));
    final bRect = tester.getRect(find.text('港B'));
    expect((aRect.top - bRect.top).abs(), lessThan(20),
        reason: '两节点应在同一行（双列网格）');
    expect(aRect.center.dx, lessThan(bRect.center.dx),
        reason: '港A 应在港B 左侧（双列）');

    // 节点网格在分组栏右侧。
    final railRight = tester.getTopRight(find.text('线路分组')).dx;
    expect(aRect.left, greaterThan(railRight), reason: '节点应在左侧分组栏右侧');
  });
}
