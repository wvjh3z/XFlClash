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

import 'package:fl_clash/models/models.dart' show Group;
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/proxies/common.dart' as proxies_common;
import 'package:fl_clash/views/proxies/tab.dart' show ProxyGroupView;
import 'package:fl_clash/enum/enum.dart' show GroupType, ProxyCardType;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单个分组的轻量摘要（primitive only，防类型穿透）。
class XbGroupSummary {
  const XbGroupSummary({
    required this.name,
    required this.nodeCount,
    required this.currentSelected,
    required this.isUrlTest,
  });

  /// 分组名。
  final String name;

  /// 分组内节点数。
  final int nodeCount;

  /// 当前选中节点名（空 = 未选 / 自动）。
  final String currentSelected;

  /// 是否 url-test 自动选优组（首项标「自动」用，R4.3）。
  final bool isUrlTest;
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

  XbGroupSummary _toSummary(Group group) => XbGroupSummary(
        name: group.name,
        nodeCount: group.all.length,
        currentSelected: group.now ?? '',
        isUrlTest: group.type == GroupType.URLTest,
      );

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
  void selectNode(WidgetRef ref, String groupName, String proxyName) {
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, proxyName);
    ref
        .read(proxiesActionProvider.notifier)
        .changeProxyDebounce(groupName, proxyName);
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
