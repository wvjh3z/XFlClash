/// 形态 A 节点适配器（spec `xboard-form-a-ui-revamp` / W2.4 / R4.1·R4.5）。
///
/// **职责（风险②b 收口）**：把 FlClash 节点分组 / 选中 / 选择写回 / 刷新竞速收口。
/// - `nodesView`：从 `proxiesTabStateProvider` 投影**轻量** `XbNodesView`（分组名 + 数量 +
///   当前选中，全 primitive，不让 FlClash `Group`/`Proxy` 类型穿透到 Tab，防风险②类型耦合）。
/// - `groupView(name)`：返回**直接复用**的 FlClash `ProxyGroupView`（它内含 `ProxyCard`，
///   已封装节点行渲染 + 选择两步），节点页 body 直接挂它（◆ 经 adapter 复用）。
/// - `selectNode`：⚠️ **必须两步**（card.dart:103-112 同源）——① `updateCurrentSelectedMap`
///   持久化选择 ② `changeProxyDebounce` 调 core 切换 + reset/close 连接。只调一步会让
///   UI/core/持久化脱节（design 风险②）。
/// - `refresh` / `testGroupDelay`：从上到下顺序 + 并发 10 竞速（`runBatchedConcurrent`，
///   调单节点 `proxyDelayTest`，不碰上游 `delayTest` 的 100 并发实现）。
library;

import 'package:fl_clash/common/common.dart' show utils;
import 'package:fl_clash/models/models.dart' show Group, GroupExt, Proxy;
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/proxies/common.dart' as proxies_common;
import 'package:fl_clash/views/proxies/tab.dart' show ProxyGroupView;
import 'package:fl_clash/enum/enum.dart'
    show GroupType, GroupName, Mode, ProxyCardType;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 形态 A 节点分组类型（primitive，对应 FlClash GroupType；UI 据此分别渲染/说明）。
enum XbGroupKind {
  /// url-test：自动测速选延迟最低；可手动锁定（isComputedSelected）。
  urlTest,

  /// selector：纯手选。
  selector,

  /// fallback：故障转移；可手动锁定（isComputedSelected）。
  fallback,

  /// load-balance：负载均衡，系统自动分流，不可手选单节点。
  loadBalance,

  /// relay：链式中转，链路固定，不可手选单节点。
  relay,
}

/// 分组内单节点（primitive only，防类型穿透）。delay/选中态由 UI 经 adapter 方法实时读。
class XbNodeItem {
  const XbNodeItem({required this.name, required this.type, this.testUrl});

  /// 节点名（可能含国旗 emoji 前缀）。
  final String name;

  /// 节点协议类型（ss/vmess/… 或嵌套组名）。
  final String type;

  /// 该组测速 URL（透传给 delay 查询）。
  final String? testUrl;
}

/// 单个分组的轻量摘要（primitive only，防类型穿透）。
class XbGroupSummary {
  const XbGroupSummary({
    required this.name,
    required this.nodeCount,
    required this.currentSelected,
    required this.isUrlTest,
    required this.kind,
    required this.nodes,
    this.testUrl,
  });

  /// 分组名。
  final String name;

  /// 分组内节点数。
  final int nodeCount;

  /// 当前选中节点名（空 = 未选 / 自动）。
  final String currentSelected;

  /// 是否 url-test 自动选优组（首项标「自动」用，R4.3）。
  final bool isUrlTest;

  /// 分组类型（UI 据此渲染类型标签 + 决定是否可手选）。
  final XbGroupKind kind;

  /// 分组内节点（自绘节点行用）。
  final List<XbNodeItem> nodes;

  /// 分组测速 URL。
  final String? testUrl;

  /// 是否可手选单节点（url-test/selector/fallback 可；load-balance/relay 只读）。
  bool get isSelectable =>
      kind == XbGroupKind.urlTest ||
      kind == XbGroupKind.selector ||
      kind == XbGroupKind.fallback;

  /// 是否「计算选择」组（url-test/fallback：首项标「自动」，可锁定/跟自动）。
  bool get isComputed =>
      kind == XbGroupKind.urlTest || kind == XbGroupKind.fallback;
}

/// 形态 A 节点视图（轻量投影）。
class XbNodesView {
  const XbNodesView({required this.groups});

  /// 可见分组摘要列表（已过滤 hidden）。
  final List<XbGroupSummary> groups;

  /// 是否无可用分组（空态引导续费，R4.6）。
  bool get isEmpty => groups.isEmpty;
}

/// 节点适配器。
class XbNodesAdapter {
  const XbNodesAdapter();

  /// 投影轻量节点视图（过滤 hidden 组）。
  ///
  /// **mode 一致性（修复「全局选节点不生效」）**：global 模式下 core 只认 `GLOBAL` 组的选择，
  /// 故节点页 global 模式**只展示 GLOBAL 组**（用户在 GLOBAL 里选 → 与首页 GLOBAL 入口一致、
  /// 与 core 实际生效一致）。rule 模式展示业务组（`currentGroupsState` 已排除 GLOBAL）。
  XbNodesView nodesView(WidgetRef ref) {
    final tabState = ref.watch(proxiesTabStateProvider);
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final summaries = <XbGroupSummary>[];
    for (final group in tabState.groups) {
      if (group.hidden == true) continue;
      // global 模式只保留 GLOBAL 组（其余业务组在 global 下选了也不生效，隐藏避免误导）。
      if (mode == Mode.global && group.name != GroupName.GLOBAL.name) continue;
      summaries.add(_toSummary(group));
    }
    return XbNodesView(groups: summaries);
  }

  /// 当前生效的「叶子节点名 + 所属分组名」（首页线路卡用）。
  ///
  /// **数据源（多重回退，保证总能给出节点）**：
  /// 1. 用 `groupsProvider`（原始，保留 core 写入的 `now`），而非 `proxiesTabState`
  ///    （后者把 `now` 清空，未连接时取不到生效节点）。
  /// 2. 入口组**与节点页默认打开的组一致**：global → `GLOBAL` 组；rule → 首个非 GLOBAL 可见组。
  ///    **不用 `currentGroupName`**：它切 global 时被 FlClash 永久写成 "GLOBAL"，切回 rule 不复位，
  ///    会导致 rule 模式误显示 GLOBAL（污染）。
  /// 3. 每层选中：`getCurrentSelectedName(selectedMap[组名])`（computed 组用 now、否则 selectedMap）；
  ///    **若为空 → 回退该组首个真实节点**（覆盖「全局首次未手选、selectedMap 无该组」场景，
  ///    避免显示不了）。
  /// 4. 沿链下钻到真实节点（非分组名）：`node`=叶子节点名，`group`=叶子的直接父分组名。
  ///
  /// 全空（无任何组/节点）→ (null, null)。
  ({String? node, String? group}) currentSelection(WidgetRef ref) {
    final mode = ref.watch(
      patchClashConfigProvider.select((s) => s.mode),
    );
    final groups = ref.watch(groupsProvider);
    if (groups.isEmpty) return (node: null, group: null);
    final selectedMap = ref.watch(selectedMapProvider);

    Group? byName(String name) {
      for (final g in groups) {
        if (g.name == name) return g;
      }
      return null;
    }

    // 入口组：global → GLOBAL 组；rule → 首个非 GLOBAL 可见组（与节点页默认组一致，
    // 不依赖会被污染的 currentGroupName）。
    Group? cur = mode == Mode.global
        ? (byName(GroupName.GLOBAL.name) ?? groups.first)
        : groups.firstWhere(
            (g) => g.hidden != true && g.name != GroupName.GLOBAL.name,
            orElse: () => groups.first,
          );

    const builtin = {'DIRECT', 'REJECT', 'GLOBAL', 'PASS', 'COMPATIBLE'};
    String? leaf;
    String? parentGroup;
    final seen = <String>{}; // 防环。
    while (cur != null && seen.add(cur.name)) {
      final hasExplicit = selectedMap.containsKey(cur.name) &&
          selectedMap[cur.name]!.isNotEmpty;
      // 每层选中优先级：
      // ① 用户显式选择（selectedMap 有值）→ 尊重（含主动选 DIRECT）；
      // ② 否则 core 运行值 now（computed 组语义）；
      // ③ 若①②落空或解析到内置项(DIRECT 等) 且非用户显式 → 回退首个真实节点
      //    （不默认直连：用户用 VPN 不会想只直连）。
      var selected = cur.getCurrentSelectedName(selectedMap[cur.name] ?? '');
      if (selected.isEmpty || (!hasExplicit && builtin.contains(selected))) {
        final real = _firstRealNode(cur);
        if (real.isNotEmpty) selected = real;
      }
      if (selected.isEmpty) break;
      leaf = selected;
      parentGroup = cur.name;
      final next = byName(selected); // 仍是分组 → 继续下钻；否则就是叶子节点。
      if (next == null) break;
      cur = next;
    }
    // 最终仍落在内置项（如整组只有 DIRECT 且非用户显式）→ 视为未选。
    if (leaf != null && builtin.contains(leaf)) {
      final rootExplicit = parentGroup != null &&
          selectedMap[parentGroup]?.isNotEmpty == true &&
          builtin.contains(selectedMap[parentGroup]);
      if (!rootExplicit) return (node: null, group: null);
    }
    return (node: leaf, group: parentGroup);
  }

  /// 取分组首个「真实可用」候选：第一个非内置(DIRECT/REJECT/GLOBAL/PASS/COMPATIBLE)项
  /// （子组名也算候选，下钻会继续解析）。**不兜底 all.first** —— 避免在用户未选时
  /// 默认落到 DIRECT（直连违背用 VPN 的初衷）。无真实候选 → 返回 ''（视为未选）。
  String _firstRealNode(Group group) {
    const builtin = {'DIRECT', 'REJECT', 'GLOBAL', 'PASS', 'COMPATIBLE'};
    for (final p in group.all) {
      if (builtin.contains(p.name)) continue;
      return p.name;
    }
    return '';
  }

  XbGroupSummary _toSummary(Group group) {
    final kind = _kindOf(group.type);
    return XbGroupSummary(
      name: group.name,
      nodeCount: group.all.length,
      currentSelected: group.now ?? '',
      isUrlTest: group.type == GroupType.URLTest,
      kind: kind,
      testUrl: group.testUrl,
      nodes: [
        for (final p in group.all)
          XbNodeItem(name: p.name, type: p.type, testUrl: group.testUrl),
      ],
    );
  }

  XbGroupKind _kindOf(GroupType type) => switch (type) {
        GroupType.URLTest => XbGroupKind.urlTest,
        GroupType.Selector => XbGroupKind.selector,
        GroupType.Fallback => XbGroupKind.fallback,
        GroupType.LoadBalance => XbGroupKind.loadBalance,
        GroupType.Relay => XbGroupKind.relay,
      };

  /// 某节点当前延迟（ms）；null = 未测 / 0 = 测速中 / >0 ms / <0 超时（语义同 FlClash）。
  /// 经本 adapter 收口 `delayProvider`（适配层铁律，Tab 不直接 import FlClash provider）。
  int? nodeDelay(WidgetRef ref, {required String proxyName, String? testUrl}) =>
      ref.watch(delayProvider(proxyName: proxyName, testUrl: testUrl));

  /// 某组当前生效选中节点名（计算选择组返回自动命中的节点，selector 返回手选）。
  String? selectedName(WidgetRef ref, String groupName) =>
      ref.watch(selectedProxyNameProvider(groupName));

  /// 延迟着色（复用 FlClash `utils.getDelayColor`，口径一致）。
  Color? delayColor(int? delay) => utils.getDelayColor(delay);

  /// 并发上限（测延迟/刷新）：从上到下顺序、每批最多并发 [_kDelayConcurrency] 个，
  /// 批内并发、批间串行。比上游 `delayTest` 的 100 并发更克制（避免瞬时打满连接），
  /// 代价是含超时节点时整体较慢（每批被最慢节点拖到 ~5s core 超时）。
  static const int _kDelayConcurrency = 10;

  /// 顺序分批竞速：按 [proxies] 原始顺序切成每批 [_kDelayConcurrency] 个，逐批并发测速。
  /// 调单节点 `proxyDelayTest`（不碰上游 `delayTest` 的 100 并发实现，守上游零侵入）。
  Future<void> _delayTestBatched(List<Proxy> proxies, String? testUrl) async {
    await runBatchedConcurrent<Proxy>(
      proxies,
      _kDelayConcurrency,
      (p) => proxies_common.proxyDelayTest(p, testUrl),
    );
  }

  /// 测速本分组所有节点（点分组头「测延迟」触发，只测该组，不波及其它组）。
  /// **从上到下顺序 + 并发 10**（`_delayTestBatched`）；各节点延迟着色经 delayProvider 自动更新。
  Future<void> testGroupDelay(WidgetRef ref, String groupName) async {
    final tabState = ref.read(proxiesTabStateProvider);
    final group = tabState.groups.firstWhere(
      (g) => g.name == groupName,
      orElse: () => throw ArgumentError('group not found: $groupName'),
    );
    await _delayTestBatched(group.all, group.testUrl);
  }

  /// 单节点测速（点击节点行延迟数字触发）。复用 `proxyDelayTest`。
  Future<void> testNode(
    WidgetRef ref, {
    required String proxyName,
    required String type,
    String? testUrl,
  }) async {
    await proxies_common.proxyDelayTest(
      Proxy(name: proxyName, type: type),
      testUrl,
    );
  }

  /// 返回直接复用的 FlClash 分组视图（含 ProxyCard 选择两步）。
  ///
  /// 节点页 body 直接挂它（◆ 经 adapter 复用，不自己拼节点行）。
  /// [columns] 列数、[cardType] 卡片形态由 Tab 传（默认从 tabState 取）。
  Widget groupView(
    WidgetRef ref,
    String groupName, {
    int? columns,
    ProxyCardType? cardType,
  }) {
    final tabState = ref.read(proxiesTabStateProvider);
    final group = tabState.groups.firstWhere(
      (g) => g.name == groupName,
      orElse: () => throw ArgumentError('group not found: $groupName'),
    );
    return ProxyGroupView(
      group: group,
      columns: columns ?? tabState.columns,
      cardType: cardType ?? tabState.proxyCardType,
    );
  }

  /// 选择节点（⚠️ 两步，card.dart:103-112 同源，缺一步则 UI/core/持久化脱节）。
  ///
  /// ① `profilesActionProvider.updateCurrentSelectedMap`（持久化选择）
  /// ② `proxiesActionProvider.changeProxyDebounce`（调 core 切换 + reset/close 连接）
  ///
  /// [computed] = url-test/fallback 计算选择组：点当前已选项 → 传空串「解锁」恢复自动；
  /// 点其它 → 锁定该节点。selector 组 [computed]=false：直接选中。
  void selectNode(
    WidgetRef ref,
    String groupName,
    String proxyName, {
    bool computed = false,
  }) {
    final next = computed
        ? (ref.read(proxyNameProvider(groupName)) == proxyName ? '' : proxyName)
        : proxyName;
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, next);
    ref
        .read(proxiesActionProvider.notifier)
        .changeProxyDebounce(groupName, next);
  }

  /// 刷新（批量竞速重测延迟）。**从上到下顺序 + 并发 10**（`_delayTestBatched`）。
  ///
  /// 对指定组（默认所有可见组）内节点批量竞速；触发后节点行延迟着色自动更新（R4.5）。
  Future<void> refresh(WidgetRef ref, {String? groupName}) async {
    final tabState = ref.read(proxiesTabStateProvider);
    final groups = groupName == null
        ? tabState.groups
        : tabState.groups.where((g) => g.name == groupName);
    for (final group in groups) {
      await _delayTestBatched(group.all, group.testUrl);
    }
  }
}

/// 节点适配器单例 provider（Tab 经此取，测试可 override）。
final xbNodesAdapterProvider = Provider<XbNodesAdapter>(
  (ref) => const XbNodesAdapter(),
);

/// 顺序分批并发执行（纯函数，可单测）：把 [items] 按原始顺序切成每批 [concurrency] 个，
/// **批内并发（Future.wait）、批间串行**（上一批全完成才开下一批）→ 整体从上到下推进。
/// [task] 对单个元素执行异步操作。[concurrency] ≤0 时按 1 处理（全串行）。
Future<void> runBatchedConcurrent<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T item) task,
) async {
  final step = concurrency < 1 ? 1 : concurrency;
  for (var i = 0; i < items.length; i += step) {
    final end = (i + step) > items.length ? items.length : (i + step);
    await Future.wait(items.sublist(i, end).map(task));
  }
}
