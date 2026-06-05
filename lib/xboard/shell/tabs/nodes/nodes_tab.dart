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
import 'package:fl_clash/xboard/widgets/xb_components.dart';

import '../../adapters/xb_nodes_adapter.dart';

/// 节点 Tab。
class NodesTab extends ConsumerWidget {
  const NodesTab({super.key, this.onTapRenew, this.onTapLogin});

  /// 空态点击续费（shell/我的 注入）。
  final VoidCallback? onTapRenew;

  /// 游客点击登录（shell 注入）。
  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;
    if (isGuest) {
      return _GuestNodes(onTapLogin: onTapLogin);
    }

    final adapter = ref.watch(xbNodesAdapterProvider);
    final view = adapter.nodesView(ref);

    if (view.isEmpty) {
      return _EmptyNodes(onTapRenew: onTapRenew);
    }

    return Column(
      children: [
        _NodesHeader(onRefresh: () => adapter.refresh(ref)),
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

/// 顶部刷新条（R4.5）—— 原型「选择线路」标题 + 「刷新节点」。
class _NodesHeader extends StatelessWidget {
  const _NodesHeader({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: XbScreenTitle(
        '选择线路',
        trailing: TextButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('刷新节点'),
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

/// 空态：无可用分组 → 引导续费（R4.6，复用 XbEmptyState）。
class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes({this.onTapRenew});

  final VoidCallback? onTapRenew;

  @override
  Widget build(BuildContext context) {
    return XbEmptyState(
      icon: Icons.cloud_off,
      title: '当前套餐无可用线路',
      description: '套餐可能已到期或未生效，\n续费后线路将自动同步。',
      actionLabel: '前往续费',
      onAction: onTapRenew,
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
