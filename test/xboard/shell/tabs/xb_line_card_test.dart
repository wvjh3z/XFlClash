/// W3.3 — XbLineCard 单测（选中节点+分组 / selectedMap 链 / 全局默认 / 空态 / 点击）。
///
/// 适配器 currentSelection 数据源：`groupsProvider`(保留 core now) + `selectedMapProvider`
/// + `patchClashConfigProvider`(mode) + `currentProfileProvider`(currentGroupName)。
/// 测试用 groupsProvider/selectedMap/mode override；currentGroupName 走「首个非 GLOBAL」回退。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show Group, Proxy, PatchClashConfig;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/providers.dart'
    show selectedMapProvider, groupsProvider, currentProfileProvider;
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_line_card.dart';

Future<void> pumpCard(
  WidgetTester tester, {
  required bool isStart,
  required List<Group> groups,
  Map<String, String> selectedMap = const {},
  Mode mode = Mode.rule,
  VoidCallback? onTap,
}) async {
  final container = ProviderContainer(
    overrides: [
      isStartProvider.overrideWith((ref) => isStart),
      groupsProvider.overrideWithValue(groups),
      selectedMapProvider.overrideWith((ref) => selectedMap),
      currentProfileProvider.overrideWith((ref) => null),
      patchClashConfigProvider
          .overrideWithBuild((ref, _) => PatchClashConfig(mode: mode)),
    ],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(true);
  container.read(coreStatusProvider.notifier).value =
      isStart ? CoreStatus.connected : CoreStatus.disconnected;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
            body: XbLineCard(
                onTapToNodes:
                    onTap == null ? null : (group, node) => onTap())),
      ),
    ),
  );
  await tester.pump();
}

/// 单层 selector 组（now 由 core 填，未连接则空）。
List<Group> _singleGroup({String? now}) => [
      Group(
        type: GroupType.Selector,
        name: '智能优选',
        now: now,
        all: const [Proxy(name: '香港01', type: 'ss'), Proxy(name: '香港02', type: 'ss')],
      ),
    ];

void main() {
  testWidgets('已连接 → 上行节点名 + 下行「当前分组：X」（now 来自 core）', (tester) async {
    await pumpCard(tester, isStart: true, groups: _singleGroup(now: '香港01'));
    expect(find.text('香港01'), findsOneWidget);
    expect(find.text('当前分组：智能优选'), findsOneWidget);
  });

  testWidgets('未连接(now 全空) → 沿 selectedMap 链下钻显示叶子节点 + 所属分组', (tester) async {
    await pumpCard(
      tester,
      isStart: false,
      selectedMap: const {'智能优选': '香港', '香港': '🇭🇰 香港 BGP 02'},
      groups: const [
        Group(
          type: GroupType.Selector,
          name: '智能优选',
          all: [Proxy(name: '香港', type: 'Selector'), Proxy(name: '日本', type: 'Selector')],
        ),
        Group(
          type: GroupType.Selector,
          name: '香港',
          all: [Proxy(name: '🇭🇰 香港 BGP 02', type: 'ss')],
        ),
      ],
    );
    expect(find.text('🇭🇰 香港 BGP 02'), findsOneWidget);
    expect(find.text('当前分组：香港'), findsOneWidget);
  });

  testWidgets('未连接 + selectedMap 无该组 → 回退首个真实节点（不再显示「未选择」）',
      (tester) async {
    // 用户从未手选、core 未运行：仍应显示该组首个真实节点（跳过 DIRECT 等内置）。
    await pumpCard(
      tester,
      isStart: false,
      groups: const [
        Group(
          type: GroupType.Selector,
          name: '智能优选',
          all: [Proxy(name: 'DIRECT', type: 'Direct'), Proxy(name: '香港01', type: 'ss')],
        ),
      ],
    );
    expect(find.text('香港01'), findsOneWidget);
    expect(find.text('当前分组：智能优选'), findsOneWidget);
    expect(find.text('未选择线路'), findsNothing);
  });

  testWidgets('全局模式首次 → 入口取 GLOBAL 组 + 回退默认节点', (tester) async {
    await pumpCard(
      tester,
      isStart: false,
      mode: Mode.global,
      groups: const [
        // 业务组在前，但 global 模式入口应取 GLOBAL。
        Group(
          type: GroupType.Selector,
          name: '智能优选',
          all: [Proxy(name: '香港01', type: 'ss')],
        ),
        Group(
          type: GroupType.Selector,
          name: 'GLOBAL',
          all: [Proxy(name: '🇯🇵 东京 01', type: 'ss'), Proxy(name: '香港01', type: 'ss')],
        ),
      ],
    );
    // GLOBAL 组首个真实节点。
    expect(find.text('🇯🇵 东京 01'), findsOneWidget);
    expect(find.text('当前分组：GLOBAL'), findsOneWidget);
  });

  testWidgets('无任何分组 → 占位「未选择线路」', (tester) async {
    await pumpCard(tester, isStart: false, groups: const []);
    expect(find.text('未选择线路'), findsOneWidget);
    expect(find.text('连接后自动优选'), findsOneWidget);
  });

  testWidgets('点击 → 触发切节点 Tab 回调', (tester) async {
    var tapped = false;
    await pumpCard(tester,
        isStart: true, groups: _singleGroup(now: '香港01'), onTap: () => tapped = true);
    await tester.tap(find.byType(XbLineCard));
    expect(tapped, isTrue);
  });

  testWidgets('点击回调带出选中节点的分组+节点名（供节点页定位）', (tester) async {
    String? gotGroup;
    String? gotNode;
    final container = ProviderContainer(
      overrides: [
        isStartProvider.overrideWith((ref) => true),
        groupsProvider.overrideWithValue(const [
          Group(
            type: GroupType.Selector,
            name: '香港',
            now: '🇭🇰 香港 BGP 02',
            all: [Proxy(name: '🇭🇰 香港 BGP 02', type: 'ss')],
          ),
        ]),
        selectedMapProvider.overrideWith((ref) => const {'香港': '🇭🇰 香港 BGP 02'}),
        currentProfileProvider.overrideWith((ref) => null),
        patchClashConfigProvider
            .overrideWithBuild((ref, _) => const PatchClashConfig(mode: Mode.rule)),
      ],
    );
    addTearDown(container.dispose);
    container.read(bootstrapReadyProvider.notifier).set(true);
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: XbLineCard(
              onTapToNodes: (g, n) {
                gotGroup = g;
                gotNode = n;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(XbLineCard));
    expect(gotGroup, '香港');
    expect(gotNode, '🇭🇰 香港 BGP 02');
  });
}
