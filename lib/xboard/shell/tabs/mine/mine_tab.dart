/// 形态 A 我的 Tab（spec `xboard-form-a-ui-revamp` / W4.3·W4.4·W4.5 / R6.1-R6.11）。
///
/// 组装：账号卡（W4.3，复用形态 B `userProfileProvider`，F14 先 gate authState）+ 续费/购买
/// 分流（W4.4，R6.4-R6.6）+ 流量重置入口（用量 ≥90% 才显示，R6.3）+ 设置入口（W4.5，经
/// `XbNativePageAdapter` push 原生 ToolsView，R6.8）+ 退出登录（◇ 复用形态 B logout 编排，R6.11）。
///
/// **复用边界**：账户/套餐/订单/支付/登出全链路 = ◇ **复用形态 B `lib/xboard/`**（自有代码，
/// 不经 adapter，无风险②）；仅设置入口（原生 ToolsView）= ◆ 经 `XbNativePageAdapter`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';
import 'package:fl_clash/xboard/pages/plan_list_page.dart';
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';

import '../../adapters/xb_native_page_adapter.dart';

/// 用量达此比例才显示「流量重置」入口（R6.3）。
const _resetThreshold = 0.90;

/// 我的 Tab。
class MineTab extends ConsumerWidget {
  const MineTab({super.key, this.onTapLogin});

  /// 游客点击登录（shell 注入，W5 接线）。
  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text('我的', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          if (isGuest)
            _GuestCard(onTapLogin: onTapLogin)
          else
            const _AccountSection(),
          const SizedBox(height: 16),
          _SettingsSection(isGuest: isGuest),
        ],
      ),
    );
  }
}

/// 已登录账号区：账号卡（loading 骨架 / data）+ 续费购买分流 + 重置入口。
class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // F14：已 gate authenticated（MineTab 已判 isGuest），可安全 watch。
    final async = ref.watch(userProfileProvider);
    return async.when(
      loading: () => const _AccountSkeleton(),
      error: (e, _) => _AccountErrorCard(
        onRetry: () => ref.invalidate(userProfileProvider),
      ),
      data: (sub) => Column(
        children: [
          _AccountCard(sub: sub),
          const SizedBox(height: 12),
          _PlanActions(sub: sub),
        ],
      ),
    );
  }
}

/// 账号卡（邮箱 + 套餐 + 用量% + 到期 + 重置日，R6.1/R6.2）。
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.sub});

  final XbDomainSubscription sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usedPct = sub.totalBytes == 0
        ? 0.0
        : (sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0);

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primary.withValues(alpha: 0.12),
                  child: Icon(Icons.person, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _maskEmail(sub.email),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sub.planName ?? '未订阅套餐',
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 用量进度（%，R6.2）。
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: usedPct,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '已用 ${_gb(sub.usedBytes)} / ${_gb(sub.totalBytes)} GB',
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
                Text(
                  '${(usedPct * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: usedPct >= _resetThreshold
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.event, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  _expireText(sub),
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _gb(int bytes) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

  static String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 1) return email;
    final name = email.substring(0, at);
    final masked = name.length <= 2
        ? '${name[0]}*'
        : '${name.substring(0, 2)}***';
    return '$masked${email.substring(at)}';
  }

  static String _expireText(XbDomainSubscription sub) {
    if (sub.expiredAt == null) return '长期有效';
    final d = sub.expiredAt!;
    return '到期 ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

/// 续费/购买分流（R6.4/R6.5/R6.6）+ 流量重置入口（≥90%，R6.3）。
class _PlanActions extends StatelessWidget {
  const _PlanActions({required this.sub});

  final XbDomainSubscription sub;

  @override
  Widget build(BuildContext context) {
    final usedPct = sub.totalBytes == 0
        ? 0.0
        : (sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0);
    final showReset = usedPct >= _resetThreshold && sub.planId != null;

    return Column(
      children: [
        Row(
          children: [
            // 续费当前套餐（R6.4）：有套餐才显示。
            if (!sub.hasNoPlan)
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _openPlans(context),
                  icon: const Icon(Icons.autorenew, size: 18),
                  label: const Text('续费套餐'),
                ),
              ),
            if (!sub.hasNoPlan) const SizedBox(width: 12),
            // 购买/更改套餐（R6.5/R6.6）。
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _openPlans(context),
                icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                label: Text(sub.hasNoPlan ? '购买套餐' : '更改套餐'),
              ),
            ),
          ],
        ),
        if (showReset) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openReset(context, sub),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('流量重置'),
            ),
          ),
        ],
      ],
    );
  }

  // ◇ 复用形态 B 套餐页（不经 adapter）。
  void _openPlans(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PlanListPage()),
    );
  }

  void _openReset(BuildContext context, XbDomainSubscription sub) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ResetTrafficPage(planId: sub.planId!, planName: sub.planName),
      ),
    );
  }
}

/// 加载骨架（已登录未就绪，R6.9）。
class _AccountSkeleton extends StatelessWidget {
  const _AccountSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: const Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SkeletonBar(widthFactor: 0.5, height: 16),
            SizedBox(height: 12),
            _SkeletonBar(widthFactor: 1, height: 8),
            SizedBox(height: 10),
            _SkeletonBar(widthFactor: 0.7, height: 12),
            SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.sync, size: 16),
                SizedBox(width: 8),
                Text('正在同步账号信息…', style: TextStyle(fontSize: 12.5)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.widthFactor, required this.height});

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}

class _AccountErrorCard extends StatelessWidget {
  const _AccountErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.cloud_off, color: scheme.onSurfaceVariant),
            const SizedBox(height: 8),
            const Text('账号信息加载失败'),
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 游客引导卡（R6.10）。
class _GuestCard extends StatelessWidget {
  const _GuestCard({this.onTapLogin});

  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.account_circle_outlined,
                size: 48, color: scheme.primary),
            const SizedBox(height: 12),
            const Text('登录后管理你的套餐与流量',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onTapLogin,
                child: const Text('登录 / 注册'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置入口区（设置 / 订单 / 退出登录，R6.8/R6.11）。
class _SettingsSection extends ConsumerWidget {
  const _SettingsSection({required this.isGuest});

  final bool isGuest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          if (!isGuest)
            _SettingsTile(
              icon: Icons.receipt_long,
              label: '我的订单',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const OrderListPage()),
              ),
            ),
          // 设置 → 原生 ToolsView（R6.8，经 adapter）。
          _SettingsTile(
            icon: Icons.settings,
            label: '设置',
            onTap: () =>
                ref.read(xbNativePageAdapterProvider).openTools(context),
          ),
          if (!isGuest)
            _SettingsTile(
              icon: Icons.logout,
              label: '退出登录',
              danger: true,
              // ◇ 复用形态 B 登出编排（R6.11）。
              onTap: () => ref.read(authStateProvider.notifier).logout(),
            ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger ? scheme.error : scheme.onSurface;
    return ListTile(
      leading: Icon(icon, color: danger ? scheme.error : scheme.onSurfaceVariant),
      title: Text(label, style: TextStyle(color: color)),
      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      onTap: onTap,
    );
  }
}
