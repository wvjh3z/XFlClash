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

/// 顶部刷新条（R4.5）。
class _NodesHeader extends StatelessWidget {
  const _NodesHeader({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Text('线路', style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('刷新'),
          ),
        ],
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
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '自动',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
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

/// 空态：无可用分组 → 引导续费（R4.6，不显示搜索/分组标签）。
class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes({this.onTapRenew});

  final VoidCallback? onTapRenew;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('暂无可用线路', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '订阅套餐后即可使用专属线路',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onTapRenew,
              child: const Text('查看套餐'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 游客态：登录后查看专属线路（R4.7）。
class _GuestNodes extends StatelessWidget {
  const _GuestNodes({this.onTapLogin});

  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.vpn_lock, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('登录后查看专属线路', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onTapLogin,
              child: const Text('登录 / 注册'),
            ),
          ],
        ),
      ),
    );
  }
}
