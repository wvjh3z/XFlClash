/// 形态 A 节点页 golden 核对（优选 url-test / 选择器 selector / 空态）。
///
/// 对照移动原型 nodes(kind)：标题操作胶囊、分组标签、节点行和游客登录引导。
/// 用 ProxiesTabState + adapter provider override 注入假数据，不触真实内核 DB。
library;

import 'golden_environment.dart';
import 'shell_fixture.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxiesTabState, Group, Proxy;
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/nodes_tab.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
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
      proxyCardType: ProxyCardType.standard,

    );

Future<void> pumpNodes(
  WidgetTester tester, {
  required AuthState auth,
  ProxiesTabState? tab,
  XbDomainSubscription? sub,
  VoidCallback? onLogin,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final state = tab ?? _tab();
  final overrides = [
    authStateProvider.overrideWith(() => _FakeAuth(auth)),
    proxiesTabStateProvider.overrideWith((ref) => state),
    if (sub != null) userProfileProvider.overrideWith((ref) async => sub),
  ];
  // 固定每组选中态 + 每节点延迟（good 档），避免触达真实内核。
  // 去重：不同分组可能含同名节点（同 proxyName+testUrl），delayProvider 不能重复 override。
  var delay = 38;
  final seenDelayKeys = <String>{};
  for (final g in state.groups) {
    overrides.add(selectedProxyNameProvider(g.name).overrideWithValue(g.now));
    overrides.add(proxyNameProvider(g.name).overrideWithValue(null));
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
        home: Scaffold(
          body: XbBrandTheme(brandColor: const Color(0xFFD92E1A), child: NodesTab(onTapLogin: onLogin)),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('节点 · 优选分组(url-test) golden + 结构对照原型', (t) async {
    await pumpShell(t, core: CoreStatus.connected, mobile:true, size:const Size(390,844));
    await t.tap(find.text('节点').hitTestable());
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    // 结构对照原型 nodes('recommend')：标题右侧的测速 / 刷新胶囊，随后是分组标签和节点。
    // 注：分组 tab / 节点名经 EmojiText（=RichText）渲染，find.text 默认不匹配 RichText，
    //     故全部加 findRichText: true（纯增量，仍匹配普通 Text）。
    expect(find.text('选择线路', findRichText: true), findsOneWidget);
    final capsule = find.byKey(const ValueKey('nodes-action-capsule'));
    expect(t.getSize(capsule), const Size(157, 48));
    expect(find.descendant(of: capsule, matching: find.text('刷新节点')), findsOneWidget);
    expect(find.text('优选', findRichText: true), findsWidgets); // 顶部分组 tab
    expect(find.text('香港', findRichText: true), findsWidgets);
    expect(find.descendant(of: capsule, matching: find.text('测延迟')), findsOneWidget);
    expect(find.text('自动', findRichText: true), findsOneWidget); // url-test 首项「自动」标
    expect(find.textContaining('url-test', findRichText: true),
        findsNothing); // 类型说明已按产品要求移除，PNG基线需另外论证与验收。
    expect(find.text('🇯🇵 东京 IEPL 02', findRichText: true), findsOneWidget);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/nodes_recommend.png');
  });

  testWidgets('节点 · 游客态 golden', (t) async {
    await pumpShell(t, core: CoreStatus.disconnected, auth:AuthState.unauthenticated, mobile:true, size:const Size(390,844));
    await t.tap(find.text('节点').hitTestable());
    await t.pumpAndSettle();
    expect(find.text('选择线路'), findsOneWidget);
    expect(find.byKey(const ValueKey('nodes-action-capsule')), findsNothing);
    expect(t.getSize(find.byKey(const ValueKey('nodes-guest-badge'))), const Size(80, 80));
    expect(find.byKey(const ValueKey('nodes-guest-login-gradient')), findsOneWidget);
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/nodes_guest.png');
    expect(find.text('立即登录').hitTestable(), findsOneWidget);
  });

  testWidgets('节点 · 空态(无线路) golden', (t) async {
    await pumpNodes(
      t,
      auth: AuthState.authenticated,
      tab: const ProxiesTabState(
        groups: [],
        currentGroupName: null,
        proxyCardType: ProxyCardType.standard,

      ),
    );
    expect(t.takeException(), isNull);
    await expectXbGolden(t, find.byType(NodesTab), 'goldens/nodes_empty.png');
  });

  testWidgets('节点 · 套餐已过期 → 清空节点 + 引导续费/购买 golden', (t) async {
    // 有缓存节点（_tab 默认带分组），但订阅已过期 → 应清空并显示空态。
    await pumpNodes(
      t,
      auth: AuthState.authenticated,
      sub: _subscription(
        expiredAt: DateTime(2020, 1, 1), // 过去 → 已过期
        usedBytes: 30 * 1024 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024 * 1024,
      ),
    );
    expect(t.takeException(), isNull);
    // 过期 → 清空节点，显示无可用线路空态（引导续费/购买），节点名不再出现。
    expect(find.text('当前无可用线路'), findsOneWidget);
    expect(find.text('前往续费 / 购买'), findsOneWidget);
    expect(find.text('🇯🇵 东京 IEPL 02'), findsNothing);
    await expectXbGolden(t, find.byType(NodesTab), 'goldens/nodes_expired.png');
  });

  testWidgets('节点 · 流量已用尽 → 清空节点 + 购买流量包/套餐 golden', (t) async {
    await pumpNodes(
      t,
      auth: AuthState.authenticated,
      sub: _subscription(
        expiredAt: DateTime(2030, 1, 1), // 未来 → 未过期
        usedBytes: 100 * 1024 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024 * 1024, // 用尽
      ),
    );
    expect(t.takeException(), isNull);
    expect(find.text('当前套餐流量已用尽'), findsOneWidget);
    expect(find.text('购买流量包'), findsOneWidget);
    expect(find.text('购买 / 更改套餐'), findsOneWidget);
    expect(find.text('🇯🇵 东京 IEPL 02'), findsNothing);
    await expectXbGolden(t, find.byType(NodesTab), 'goldens/nodes_exhausted.png');
  });
}

/// 构造测试订阅（过期/用尽场景）。
XbDomainSubscription _subscription({
  required DateTime expiredAt,
  required int usedBytes,
  required int totalBytes,
}) =>
    XbDomainSubscription(
      email: 'demo@example.com',
      uuid: 'uid-1',
      planName: '标准套餐',
      totalBytes: totalBytes,
      usedBytes: usedBytes,
      expiredAt: expiredAt,
      planId: 1,
    );
