/// XbNodesAdapter 节点选择 + 模式切换 完整矩阵回归。
///
/// 覆盖：
/// - 同组内节点切换（rule）：选香港/日本/DIRECT，首页跟随；
/// - 模式切换序列：rule→global→rule（含 currentGroupName 被污染的回归）；
/// - global 入口取 GLOBAL、rule 入口取首个业务组（不依赖 currentGroupName）；
/// - 节点页 nodesView 按 mode 过滤（global 只剩 GLOBAL；rule 不含 GLOBAL）；
/// - 多层下钻（主组选子组 → 下钻到叶子）；
/// - 边界：未手选回退首个真实节点 / computed 组用 now / 空组。
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
    show selectedMapProvider, groupsProvider;
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
const _hk = '🇭🇰 香港1';
const _jp = '🇯🇵 日本1';
const _sg = '🇸🇬 新加坡1';

/// 真实 omofly 结构：手动选择(select) + 自动选择(url-test) + GLOBAL(core 生成)。
/// [manualNow]/[autoNow]/[globalNow] 模拟 core 写入的运行时 now。
List<Group> _groups({
  String? manualNow,
  String autoNow = _hk,
  String? globalNow,
  bool includeGlobal = true,
}) {
  return [
    Group(
      type: GroupType.Selector,
      name: 'omofly 手动选择',
      now: manualNow,
      all: const [
        Proxy(name: 'DIRECT', type: 'Direct'),
        Proxy(name: '自动选择', type: 'URLTest'),
        Proxy(name: _hk, type: 'ss'),
        Proxy(name: _jp, type: 'ss'),
        Proxy(name: _sg, type: 'ss'),
      ],
    ),
    Group(
      type: GroupType.URLTest,
      name: '自动选择',
      now: autoNow,
      all: const [
        Proxy(name: _hk, type: 'ss'),
        Proxy(name: _jp, type: 'ss'),
        Proxy(name: _sg, type: 'ss'),
      ],
    ),
    if (includeGlobal)
      Group(
        type: GroupType.Selector,
        name: 'GLOBAL',
        now: globalNow,
        all: const [
          Proxy(name: 'DIRECT', type: 'Direct'),
          Proxy(name: 'omofly 手动选择', type: 'Selector'),
          Proxy(name: '自动选择', type: 'URLTest'),
          Proxy(name: _hk, type: 'ss'),
          Proxy(name: _jp, type: 'ss'),
          Proxy(name: _sg, type: 'ss'),
        ],
      ),
  ];
}

void main() {
  /// 读取 currentSelection（接收 WidgetRef，用 Consumer 桥接）。
  Future<({String? node, String? group})> sel(
    WidgetTester t, {
    required Mode mode,
    required List<Group> groups,
    Map<String, String> selectedMap = const {},
  }) async {
    late ({String? node, String? group}) out;
    await t.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        groupsProvider.overrideWithValue(groups),
        selectedMapProvider.overrideWith((ref) => selectedMap),
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

  /// 读取 nodesView 的可见分组名列表。
  Future<List<String>> visibleGroups(
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

  /// 读取 resolveMeasureTarget（测「选 B 却测 A」bug：旧选择在 providers，传 explicitNode）。
  Future<({String proxyName, String testUrl})?> measureTarget(
    WidgetTester t, {
    required Mode mode,
    required List<Group> groups,
    Map<String, String> selectedMap = const {},
    String? explicitNode,
  }) async {
    late ({String proxyName, String testUrl})? out;
    await t.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        groupsProvider.overrideWithValue(groups),
        selectedMapProvider.overrideWith((ref) => selectedMap),
        patchClashConfigProvider
            .overrideWithBuild((ref, _) => PatchClashConfig(mode: mode)),
      ],
      child: MaterialApp(
        home: Consumer(builder: (ctx, ref, _) {
          out = const XbNodesAdapter()
              .resolveMeasureTarget(ref, explicitNode: explicitNode);
          return const SizedBox();
        }),
      ),
    ));
    await t.pump();
    return out;
  }

  // rule 模式的 groups（currentGroupsState 已排除 GLOBAL）。
  List<Group> ruleGroups({String? manualNow}) =>
      _groups(manualNow: manualNow, includeGlobal: false);

  group('rule 模式 · 同组内节点切换', () {
    testWidgets('选香港 → 显示香港', (t) async {
      final r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _hk),
          selectedMap: {'omofly 手动选择': _hk});
      expect(r.node, _hk);
      expect(r.group, 'omofly 手动选择');
    });

    testWidgets('改选日本 → 显示日本', (t) async {
      final r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _jp),
          selectedMap: {'omofly 手动选择': _jp});
      expect(r.node, _jp);
    });

    testWidgets('改选新加坡 → 显示新加坡', (t) async {
      final r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _sg),
          selectedMap: {'omofly 手动选择': _sg});
      expect(r.node, _sg);
    });

    testWidgets('选 DIRECT → 显示 DIRECT', (t) async {
      final r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: 'DIRECT'),
          selectedMap: {'omofly 手动选择': 'DIRECT'});
      expect(r.node, 'DIRECT');
    });
  });

  group('rule 模式 · 多层下钻', () {
    testWidgets('主组选「自动选择」子组 → 下钻到子组当前节点(now)', (t) async {
      final r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: '自动选择')
            ..removeWhere((g) => g.name == 'GLOBAL'),
          selectedMap: {'omofly 手动选择': '自动选择'});
      // 自动选择(url-test) now=香港 → 叶子=香港，分组=自动选择。
      expect(r.node, _hk);
      expect(r.group, '自动选择');
    });
  });

  group('global 模式', () {
    testWidgets('入口取 GLOBAL，选日本 → 显示日本', (t) async {
      final r = await sel(t,
          mode: Mode.global,
          groups: _groups(manualNow: _hk, globalNow: _jp),
          selectedMap: {'omofly 手动选择': _hk, 'GLOBAL': _jp});
      expect(r.node, _jp);
      expect(r.group, 'GLOBAL');
    });

    testWidgets('GLOBAL 未显式选(now=DIRECT) → 回退真实节点，不默认直连', (t) async {
      final r = await sel(t,
          mode: Mode.global,
          groups: _groups(globalNow: 'DIRECT'),
          selectedMap: const {}); // 无显式
      // GLOBAL 跳过 DIRECT → 经子组下钻到真实节点；关键是绝不停在 DIRECT。
      expect(r.node, isNot('DIRECT'));
      expect(r.node, _hk);
    });

    testWidgets('GLOBAL 用户显式选 DIRECT → 尊重显示 DIRECT', (t) async {
      final r = await sel(t,
          mode: Mode.global,
          groups: _groups(globalNow: 'DIRECT'),
          selectedMap: {'GLOBAL': 'DIRECT'});
      expect(r.node, 'DIRECT');
      expect(r.group, 'GLOBAL');
    });

    testWidgets('GLOBAL 选「自动选择」子组 → 下钻到子组节点', (t) async {
      final r = await sel(t,
          mode: Mode.global,
          groups: _groups(globalNow: '自动选择', autoNow: _sg),
          selectedMap: {'GLOBAL': '自动选择'});
      expect(r.node, _sg);
      expect(r.group, '自动选择');
    });
  });

  group('模式切换序列（用户复现路径）', () {
    testWidgets('rule选香港 → 切global默认DIRECT → global选日本 → 切回rule仍香港',
        (t) async {
      // 1) rule 选香港
      var r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _hk),
          selectedMap: {'omofly 手动选择': _hk});
      expect(r.node, _hk, reason: 'step1 rule 香港');

      // 2) 切 global，GLOBAL 默认 DIRECT
      r = await sel(t,
          mode: Mode.global,
          groups: _groups(manualNow: _hk, globalNow: 'DIRECT'),
          selectedMap: {'omofly 手动选择': _hk, 'GLOBAL': 'DIRECT'});
      expect(r.node, 'DIRECT', reason: 'step2 global 默认 DIRECT');

      // 3) global 选日本
      r = await sel(t,
          mode: Mode.global,
          groups: _groups(manualNow: _hk, globalNow: _jp),
          selectedMap: {'omofly 手动选择': _hk, 'GLOBAL': _jp});
      expect(r.node, _jp, reason: 'step3 global 日本');

      // 4) 切回 rule（groups 原始含 GLOBAL，模拟 currentGroupName 被污染成 GLOBAL）
      //    → rule 入口应取业务组，显示业务组的选择(香港)，不回到 GLOBAL。
      r = await sel(t,
          mode: Mode.rule,
          groups: _groups(manualNow: _hk, globalNow: _jp),
          selectedMap: {'omofly 手动选择': _hk, 'GLOBAL': _jp});
      expect(r.group, 'omofly 手动选择', reason: 'step4 切回 rule 不应显示 GLOBAL');
      expect(r.node, _hk, reason: 'step4 rule 显示业务组选择(香港)');
    });

    testWidgets('rule 模式即使 groups 含 GLOBAL，也只从业务组取', (t) async {
      final r = await sel(t,
          mode: Mode.rule,
          groups: _groups(manualNow: _sg, globalNow: 'DIRECT'),
          selectedMap: {'omofly 手动选择': _sg, 'GLOBAL': 'DIRECT'});
      expect(r.group, 'omofly 手动选择');
      expect(r.node, _sg);
    });
  });

  group('nodesView 按 mode 过滤', () {
    testWidgets('rule → 业务组（真实 currentGroupsState 已排除 GLOBAL）', (t) async {
      // rule 模式真实喂入的 groups 本就不含 GLOBAL（currentGroupsState 已排除）。
      final names = await visibleGroups(t,
          mode: Mode.rule,
          groups: _groups(manualNow: _hk, includeGlobal: false));
      expect(names, contains('omofly 手动选择'));
      expect(names, contains('自动选择'));
      expect(names, isNot(contains('GLOBAL')));
    });

    testWidgets('global → 只剩 GLOBAL（业务组在 global 选了不生效，隐藏）', (t) async {
      final names = await visibleGroups(t,
          mode: Mode.global, groups: _groups(globalNow: 'DIRECT'));
      expect(names, ['GLOBAL']);
    });
  });

  group('边界', () {
    testWidgets('未手选 + now 空 → 回退首个真实节点（跳过 DIRECT，不默认直连）', (t) async {
      final r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(), // manualNow=null, selectedMap 空
          selectedMap: const {});
      // 跳过 DIRECT → 候选「自动选择」子组 → 下钻 now=香港。绝不返回 DIRECT。
      expect(r.node, _hk);
      expect(r.node, isNot('DIRECT'));
    });

    testWidgets('未手选 + now=DIRECT（core 默认直连）→ 不接受，回退真实节点', (t) async {
      // 模拟 core 把 now 设成 DIRECT，但用户没显式选 → 不应显示 DIRECT。
      final r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: 'DIRECT'),
          selectedMap: const {}); // 无显式选择
      expect(r.node, isNot('DIRECT'), reason: '非用户显式选 DIRECT → 回退真实节点');
      expect(r.node, _hk);
    });

    testWidgets('用户显式选 DIRECT → 尊重，显示 DIRECT', (t) async {
      final r = await sel(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: 'DIRECT'),
          selectedMap: {'omofly 手动选择': 'DIRECT'}); // 显式选 DIRECT
      expect(r.node, 'DIRECT', reason: '用户主动选 DIRECT 应尊重');
    });

    testWidgets('组内只有 DIRECT（无真实节点）+ 未显式 → 视为未选 (null)', (t) async {
      final r = await sel(t, mode: Mode.rule, groups: [
        const Group(
          type: GroupType.Selector,
          name: 'omofly 手动选择',
          now: 'DIRECT',
          all: [Proxy(name: 'DIRECT', type: 'Direct')],
        ),
      ]);
      expect(r.node, isNull, reason: '无真实节点可选 → 未选线路');
    });

    testWidgets('无任何分组 → (null, null)', (t) async {
      final r = await sel(t, mode: Mode.rule, groups: const []);
      expect(r.node, isNull);
      expect(r.group, isNull);
    });
  });

  group('resolveMeasureTarget（修「选 B 却测 A」回归）', () {
    testWidgets('切换节点：providers 旧选择=香港，传 explicitNode=日本 → 测日本（不是香港）',
        (t) async {
      // 复现 bug 时序：用户在香港，点日本。changeProxyDebounce 未落 → providers 仍是香港。
      // selectNode 传 explicitNode=日本 → 必须测日本。
      final r = await measureTarget(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _hk), // 旧选择香港仍在 providers
          selectedMap: {'omofly 手动选择': _hk},
          explicitNode: _jp); // 刚点的新节点
      expect(r, isNotNull);
      expect(r!.proxyName, _jp, reason: 'explicitNode 优先：测刚选的日本，不是旧的香港');
    });

    testWidgets('未传 explicitNode → 回退当前生效节点（连接场景，无切换）', (t) async {
      final r = await measureTarget(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _sg),
          selectedMap: {'omofly 手动选择': _sg});
      expect(r, isNotNull);
      expect(r!.proxyName, _sg);
    });

    testWidgets('explicitNode 为空串（computed 组解锁）→ 回退当前生效节点', (t) async {
      final r = await measureTarget(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _hk),
          selectedMap: {'omofly 手动选择': _hk},
          explicitNode: '');
      expect(r, isNotNull);
      expect(r!.proxyName, _hk);
    });

    testWidgets('explicitNode=子组名 → 下钻到子组真实叶子节点', (t) async {
      // 选「自动选择」url-test 子组（now=新加坡）→ 应解析到叶子新加坡。
      final r = await measureTarget(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _hk)
            ..removeWhere((g) => g.name == '自动选择')
            ..add(const Group(
              type: GroupType.URLTest,
              name: '自动选择',
              now: _sg,
              all: [
                Proxy(name: _hk, type: 'ss'),
                Proxy(name: _jp, type: 'ss'),
                Proxy(name: _sg, type: 'ss'),
              ],
            )),
          selectedMap: const {},
          explicitNode: '自动选择');
      expect(r, isNotNull);
      expect(r!.proxyName, _sg, reason: '子组下钻到 now 叶子节点');
    });

    testWidgets('explicitNode=DIRECT（内置项）→ null（不测内置，清空首页延迟）', (t) async {
      final r = await measureTarget(t,
          mode: Mode.rule,
          groups: ruleGroups(manualNow: _hk),
          selectedMap: {'omofly 手动选择': _hk},
          explicitNode: 'DIRECT');
      expect(r, isNull);
    });
  });
}
