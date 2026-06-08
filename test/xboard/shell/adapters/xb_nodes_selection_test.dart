/// XbNodesAdapter.currentSelection + nodesView 模式一致性回归
/// （复现并锁定「全局模式选节点不生效」：global 只展示 GLOBAL 组，首页入口同取 GLOBAL）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show Group, Proxy, ProxiesTabState, PatchClashConfig;
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart' show proxiesTabStateProvider;
import 'package:fl_clash/providers/providers.dart'
    show selectedMapProvider, groupsProvider, currentProfileProvider;
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';

const _hk = '🇭🇰 香港1';
const _jp = '🇯🇵 日本1';

/// 真实 omofly 结构：业务组 + core 生成的 GLOBAL（含 DIRECT 在首）。
List<Group> _groups({String? globalNow}) => [
      Group(
        type: GroupType.Selector,
        name: 'omofly 手动选择',
        now: _hk,
        all: const [
          Proxy(name: 'DIRECT', type: 'Direct'),
          Proxy(name: _hk, type: 'ss'),
          Proxy(name: _jp, type: 'ss'),
        ],
      ),
      Group(
        type: GroupType.Selector,
        name: 'GLOBAL',
        now: globalNow,
        all: const [
          Proxy(name: 'DIRECT', type: 'Direct'),
          Proxy(name: 'omofly 手动选择', type: 'Selector'),
          Proxy(name: _hk, type: 'ss'),
          Proxy(name: _jp, type: 'ss'),
        ],
      ),
    ];

void main() {
  // 用 widget pump 读取（currentSelection 接收 WidgetRef）。
  Future<({String? node, String? group})> selVia(
    WidgetTester t, {
    required Mode mode,
    required List<Group> groups,
    required Map<String, String> selectedMap,
  }) async {
    late ({String? node, String? group}) out;
    await t.pumpWidget(ProviderScope(
      overrides: [
        groupsProvider.overrideWithValue(groups),
        selectedMapProvider.overrideWith((ref) => selectedMap),
        currentProfileProvider.overrideWith((ref) => null),
        patchClashConfigProvider
            .overrideWithBuild((ref, _) => PatchClashConfig(mode: mode)),
      ],
      child: MaterialApp(
        home: Consumer(builder: (ctx, ref, _) {
          out = const XbNodesAdapter().currentSelection(ref);
          return const SizedBox();
        }),
      ),
    ));
    await t.pump();
    return out;
  }

  Future<List<String>> groupsVia(
    WidgetTester t, {
    required Mode mode,
    required List<Group> groups,
  }) async {
    late List<String> out;
    await t.pumpWidget(ProviderScope(
      overrides: [
        patchClashConfigProvider
            .overrideWithBuild((ref, _) => PatchClashConfig(mode: mode)),
        proxiesTabStateProvider.overrideWith((ref) => ProxiesTabState(
              groups: groups,
              currentGroupName: null,
              proxyCardType: ProxyCardType.expand,
              columns: 2,
            )),
      ],
      child: MaterialApp(
        home: Consumer(builder: (ctx, ref, _) {
          out = const XbNodesAdapter()
              .nodesView(ref)
              .groups
              .map((g) => g.name)
              .toList();
          return const SizedBox();
        }),
      ),
    ));
    await t.pump();
    return out;
  }

  testWidgets('rule：首页入口=业务组，选香港 → 显示香港', (t) async {
    final r = await selVia(t,
        mode: Mode.rule,
        groups: _groups()..removeWhere((g) => g.name == 'GLOBAL'),
        selectedMap: {'omofly 手动选择': _hk});
    expect(r.node, _hk);
    expect(r.group, 'omofly 手动选择');
  });

  testWidgets('global：首页入口=GLOBAL，选日本 → 显示日本（核心修复）', (t) async {
    final r = await selVia(t,
        mode: Mode.global,
        groups: _groups(globalNow: _jp),
        selectedMap: {'omofly 手动选择': _hk, 'GLOBAL': _jp});
    expect(r.node, _jp, reason: 'global 下选择应生效，而非停在旧值/DIRECT');
    expect(r.group, 'GLOBAL');
  });

  testWidgets('global：节点页只展示 GLOBAL 组（业务组在 global 下选了不生效，隐藏）',
      (t) async {
    final names = await groupsVia(t, mode: Mode.global, groups: _groups(globalNow: 'DIRECT'));
    expect(names, ['GLOBAL']);
  });

  testWidgets('rule：节点页展示业务组（不含 GLOBAL）', (t) async {
    final names = await groupsVia(t,
        mode: Mode.rule,
        groups: _groups()..removeWhere((g) => g.name == 'GLOBAL'));
    expect(names, contains('omofly 手动选择'));
    expect(names, isNot(contains('GLOBAL')));
  });
}
