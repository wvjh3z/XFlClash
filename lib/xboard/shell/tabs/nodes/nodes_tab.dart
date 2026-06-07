/// 形态 A 节点 Tab（spec `xboard-form-a-ui-revamp` / W4.1·W4.2 / R4.1-R4.7）。
///
/// 组装：刷新按钮（R4.5）+ 分组/单节点（复用 `ProxyGroupView`，R4.1/R4.2）+ 空态引导续费
/// （R4.6）+ 游客引导（R4.7）。
///
/// **适配层铁律**：全部经 `XbNodesAdapter`（W2.4）；游客态读形态 B `authStateProvider`（◇）。
/// 节点行渲染（国旗/名/延迟着色 R4.4）由复用的 `ProxyCard` 提供，不自绘。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';

import '../../adapters/xb_nodes_adapter.dart';

/// 节点 Tab。
class NodesTab extends ConsumerStatefulWidget {
  const NodesTab({super.key, this.onTapRenew, this.onTapLogin});

  /// 空态点击续费（shell/我的 注入）。
  final VoidCallback? onTapRenew;

  /// 游客点击登录（shell 注入）。
  final VoidCallback? onTapLogin;

  @override
  ConsumerState<NodesTab> createState() => _NodesTabState();
}

class _NodesTabState extends ConsumerState<NodesTab> {
  /// 正在刷新节点（重拉订阅 + 解密 + 写入新 profile）。期间刷新按钮禁用 + 顶部横幅；
  /// 旧节点保留显示（不清空），写入成功后 profile 重载自动覆盖。
  bool _refreshing = false;

  /// 刷新 = 重拉订阅并解密写入新节点（2-A）。await sync(force) 拿 `ok`（新 profile 写入成功）
  /// 才算完成；期间按钮禁用、显示横幅，完成后恢复。旧节点在写入成功前保持不变。
  Future<void> _refreshNodes() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    var outcome = XbSyncOutcome.failed;
    try {
      outcome = await ref
          .read(subscriptionServiceProvider)
          .sync(force: true);
    } catch (_) {
      // 永不抛（Property 1）；当作失败处理。
    }
    if (!mounted) return;
    setState(() => _refreshing = false);
    if (outcome != XbSyncOutcome.ok) {
      final msg = switch (outcome) {
        XbSyncOutcome.noSubscription => '当前套餐无可用线路，请购买套餐',
        XbSyncOutcome.authExpired => '登录已过期，请重新登录',
        _ => '刷新失败，请稍后重试',
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;
    if (isGuest) {
      return _GuestNodes(onTapLogin: widget.onTapLogin);
    }

    final adapter = ref.watch(xbNodesAdapterProvider);
    final view = adapter.nodesView(ref);

    // 空态：一个节点都没有。刷新中仍显示空态 + 横幅（旧节点本就为空，无可保留）。
    if (view.isEmpty) {
      return Column(
        children: [
          _NodesHeader(
            onRefresh: _refreshNodes,
            refreshing: _refreshing,
          ),
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: XbSyncBanner(text: '正在刷新节点，请稍候…'),
            ),
          Expanded(
            child: _EmptyNodes(
              onTapRenew: widget.onTapRenew,
              // 空态「刷新重试」也走重拉订阅（与顶部刷新同链路）。
              onRefresh: _refreshNodes,
            ),
          ),
        ],
      );
    }

    // 有节点：刷新中保留旧节点列表（不清空），仅顶部加横幅 + 禁用按钮，写入成功后 profile 重载覆盖。
    return Column(
      children: [
        _NodesHeader(onRefresh: _refreshNodes, refreshing: _refreshing),
        if (_refreshing)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: XbSyncBanner(text: '正在刷新节点，请稍候…'),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            itemCount: view.groups.length,
            itemBuilder: (context, i) {
              final g = view.groups[i];
              return _GroupSection(
                summary: g,
                child: adapter.groupView(ref, g.name),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 顶部刷新条（R4.5）—— 原型「选择线路」标题 + 「刷新节点」。刷新中按钮禁用 + 文案「刷新中…」。
class _NodesHeader extends StatelessWidget {
  const _NodesHeader({required this.onRefresh, this.refreshing = false});

  final VoidCallback onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: XbScreenTitle(
        '选择线路',
        trailing: TextButton.icon(
          // 刷新中禁用（null onPressed → 自动变灰不可点）。
          onPressed: refreshing ? null : onRefresh,
          icon: refreshing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh, size: 16),
          label: Text(refreshing ? '刷新中…' : '刷新节点'),
          style: TextButton.styleFrom(foregroundColor: scheme.primary),
        ),
      ),
    );
  }
}

/// 单个分组区块：分组名（url-test 标「自动」R4.3）+ 复用的节点网格。
class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.summary, required this.child});

  final XbGroupSummary summary;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Row(
            children: [
              Text(
                summary.name,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              if (summary.isUrlTest) ...[
                const SizedBox(width: 8),
                const XbTag('自动'),
              ],
              const Spacer(),
              Text(
                '${summary.nodeCount} 个节点',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        child,
      ],
    );
  }
}

/// 空态：无可用分组 → 引导续费 + 刷新重试（R4.6，复用 XbEmptyState）。
class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes({this.onTapRenew, this.onRefresh});

  final VoidCallback? onTapRenew;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return XbEmptyState(
      icon: Icons.cloud_off,
      title: '当前套餐无可用线路',
      description: '套餐可能已到期或未生效，\n续费后线路将自动同步。',
      actionLabel: '前往续费',
      onAction: onTapRenew,
      secondaryLabel: '刷新重试',
      onSecondary: onRefresh,
    );
  }
}

/// 游客态：登录后查看专属线路（R4.7，复用 XbEmptyState）。
class _GuestNodes extends StatelessWidget {
  const _GuestNodes({this.onTapLogin});

  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context) {
    return XbEmptyState(
      icon: Icons.public,
      title: '登录后查看专属线路',
      description: '高速节点由服务端下发，\n登录账号即可同步全部线路。',
      actionLabel: '立即登录',
      actionIcon: Icons.login,
      onAction: onTapLogin,
    );
  }
}
