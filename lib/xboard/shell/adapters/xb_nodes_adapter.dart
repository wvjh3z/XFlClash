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
/// - `refresh`：批量竞速（`delayTest`，复用 `lib/views/proxies/common.dart`）。
library;

import 'package:fl_clash/common/common.dart' show utils;
import 'package:fl_clash/models/models.dart' show Group, Proxy;
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/proxies/common.dart' as proxies_common;
import 'package:fl_clash/views/proxies/tab.dart' show ProxyGroupView;
import 'package:fl_clash/enum/enum.dart' show GroupType, ProxyCardType;
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
  XbNodesView nodesView(WidgetRef ref) {
    final tabState = ref.watch(proxiesTabStateProvider);
    final summaries = <XbGroupSummary>[];
    for (final group in tabState.groups) {
      if (group.hidden == true) continue;
      summaries.add(_toSummary(group));
    }
    return XbNodesView(groups: summaries);
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

  /// 测速本分组所有节点（点分组头「测延迟」触发，只测该组，不波及其它组）。
  /// 复用 `delayTest`（批量竞速）；await 完成后各节点延迟着色经 delayProvider 自动更新。
  Future<void> testGroupDelay(WidgetRef ref, String groupName) async {
    final tabState = ref.read(proxiesTabStateProvider);
    final group = tabState.groups.firstWhere(
      (g) => g.name == groupName,
      orElse: () => throw ArgumentError('group not found: $groupName'),
    );
    await proxies_common.delayTest(group.all, group.testUrl);
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

  /// 刷新（批量竞速重测延迟）。复用 `lib/views/proxies/common.dart::delayTest`。
  ///
  /// 对指定组（默认所有可见组）内节点批量竞速；触发后节点行延迟着色自动更新（R4.5）。
  Future<void> refresh(WidgetRef ref, {String? groupName}) async {
    final tabState = ref.read(proxiesTabStateProvider);
    final groups = groupName == null
        ? tabState.groups
        : tabState.groups.where((g) => g.name == groupName);
    for (final group in groups) {
      await proxies_common.delayTest(group.all, group.testUrl);
    }
  }
}

/// 节点适配器单例 provider（Tab 经此取，测试可 override）。
final xbNodesAdapterProvider = Provider<XbNodesAdapter>(
  (ref) => const XbNodesAdapter(),
);
