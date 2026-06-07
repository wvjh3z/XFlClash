/// 形态 A 节点页 golden 核对（优选 url-test / 选择器 selector / 空态）。
///
/// 对照原型 nodes(kind)：顶部分组 tab + 类型标签(?) + 测延迟 + 节点行（名/延迟/选中勾）。
/// 用 ProxiesTabState + adapter provider override 注入假数据，不触真实内核 DB。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxiesTabState, Group, Proxy;
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/nodes_tab.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

const _cjkFontPaths = [
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/System/Library/Fonts/PingFang.ttc',
];

Future<void> _loadCjkFont() async {
  for (final path in _cjkFontPaths) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final bytes = await f.readAsBytes();
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return;
    } catch (_) {}
  }
}

/// 优选(url-test) + 香港(selector) 两组，各带固定延迟（对照原型 nodes('recommend')/('hk')）。
ProxiesTabState _tab() => const ProxiesTabState(
      groups: [
        Group(
          type: GroupType.URLTest,
          name: '智能优选',
          now: '🇭🇰 香港 IEPL 专线 01',
          all: [
            Proxy(name: '🇭🇰 香港 IEPL 专线 01', type: 'ss'),
            Proxy(name: '🇯🇵 东京 IEPL 02', type: 'vmess'),
            Proxy(name: '🇸🇬 新加坡 01', type: 'trojan'),
          ],
        ),
        Group(
          type: GroupType.Selector,
          name: '香港',
          now: '🇭🇰 香港 BGP 02',
          all: [
            Proxy(name: '🇭🇰 香港 IEPL 专线 01', type: 'ss'),
            Proxy(name: '🇭🇰 香港 BGP 02', type: 'ss'),
          ],
        ),
      ],
      currentGroupName: '智能优选',
      proxyCardType: ProxyCardType.expand,
      columns: 2,
    );

Future<void> pumpNodes(
  WidgetTester tester, {
  required AuthState auth,
  ProxiesTabState? tab,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final state = tab ?? _tab();
  final overrides = [
    authStateProvider.overrideWith(() => _FakeAuth(auth)),
    proxiesTabStateProvider.overrideWith((ref) => state),
  ];
  // 固定每组选中态 + 每节点延迟（good 档），避免触达真实内核。
  // 去重：不同分组可能含同名节点（同 proxyName+testUrl），delayProvider 不能重复 override。
  var delay = 38;
  final seenDelayKeys = <String>{};
  for (final g in state.groups) {
    overrides.add(selectedProxyNameProvider(g.name).overrideWithValue(g.now));
    for (final p in g.all) {
      final key = '${p.name}|${g.testUrl}';
      if (!seenDelayKeys.add(key)) continue;
      overrides.add(
        delayProvider(proxyName: p.name, testUrl: g.testUrl)
            .overrideWithValue(delay),
      );
      delay += 14;
    }
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        home: const Scaffold(
          body: XbBrandTheme(brandColor: Color(0xFFD92E1A), child: NodesTab()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(_loadCjkFont);

  testWidgets('节点 · 优选分组(url-test) golden + 结构对照原型', (t) async {
    await pumpNodes(t, auth: AuthState.authenticated);
    expect(t.takeException(), isNull);
    // 结构对照原型 nodes('recommend')：标题「选择线路」+ 刷新节点 + 顶部分组 tab +
    // 类型标签 url-test + 测延迟 + 首项「自动」+ 节点名。
    expect(find.text('选择线路'), findsOneWidget);
    expect(find.text('刷新节点'), findsOneWidget);
    expect(find.text('智能优选'), findsWidgets); // 顶部分组 tab
    expect(find.text('香港'), findsWidgets);
    expect(find.text('测延迟'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget); // url-test 首项「自动」标
    expect(find.textContaining('url-test'), findsOneWidget); // 类型标签
    expect(find.text('🇯🇵 东京 IEPL 02'), findsOneWidget);
    await expectLater(
        find.byType(NodesTab), matchesGoldenFile('goldens/nodes_recommend.png'));
  });

  testWidgets('节点 · 游客态 golden', (t) async {
    await pumpNodes(t, auth: AuthState.unauthenticated);
    expect(t.takeException(), isNull);
    await expectLater(
        find.byType(NodesTab), matchesGoldenFile('goldens/nodes_guest.png'));
  });

  testWidgets('节点 · 空态(无线路) golden', (t) async {
    await pumpNodes(
      t,
      auth: AuthState.authenticated,
      tab: const ProxiesTabState(
        groups: [],
        currentGroupName: null,
        proxyCardType: ProxyCardType.expand,
        columns: 2,
      ),
    );
    expect(t.takeException(), isNull);
    await expectLater(
        find.byType(NodesTab), matchesGoldenFile('goldens/nodes_empty.png'));
  });
}
