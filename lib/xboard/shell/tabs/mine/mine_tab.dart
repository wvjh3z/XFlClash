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

/// 账号卡（原型 .plan：品牌渐变卡 + 白字 + 大号流量数字 + 到期/重置两行，R6.1/R6.2）。
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.sub});

  final XbDomainSubscription sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usedPct = sub.totalBytes == 0
        ? 0.0
        : (sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0);
    final pctInt = (usedPct * 100).round();
    final hot = usedPct >= _resetThreshold;
    const white = Colors.white;
    final white70 = Colors.white.withValues(alpha: 0.88);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(Colors.white.withValues(alpha: 0.18), scheme.primary),
            scheme.primary,
            Color.alphaBlend(Colors.black.withValues(alpha: 0.22), scheme.primary),
          ],
          stops: const [0, 0.55, 1],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.45),
            blurRadius: 40,
            offset: const Offset(0, 20),
            spreadRadius: -16,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 账号行：头像 + 邮箱(掩码) + 套餐名。
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                ),
                child: const Icon(Icons.person, color: white, size: 24),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _maskEmail(sub.email),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub.planName ?? '未订阅套餐',
                      style: TextStyle(fontSize: 12, color: white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 用量标签 + 大号数字。
          Text(
            '本月已用流量（已使用 $pctInt%）',
            style: TextStyle(fontSize: 12, color: white70),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _gb(sub.usedBytes),
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '/ ${_gb(sub.totalBytes)} GB',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: white70,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          // 进度条（白色填充）。
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: usedPct,
              minHeight: 10,
              backgroundColor: Colors.white.withValues(alpha: 0.25),
              valueColor: AlwaysStoppedAnimation(
                hot ? const Color(0xFFFFD9D2) : Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 11),
          // 到期行。
          _InfoRow(icon: Icons.event, text: _expireText(sub), color: white70),
          // 流量重置行（有重置日才显示）。
          if (_resetText(sub) != null) ...[
            const SizedBox(height: 3),
            _InfoRow(
                icon: Icons.autorenew, text: _resetText(sub)!, color: white70),
          ],
        ],
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

  /// 流量重置行：有重置日才显示（一次性套餐无）。
  static String? _resetText(XbDomainSubscription sub) {
    final d = sub.nextResetAt;
    if (d != null) {
      final base =
          '流量重置 ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      return sub.resetDay != null ? '$base（每月 ${sub.resetDay} 日）' : base;
    }
    if (sub.resetDay != null) return '流量重置 每月 ${sub.resetDay} 日';
    return null;
  }
}

/// 账号卡内信息行（图标 + 文案，白字半透明）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    );
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
    final pctInt = (usedPct * 100).round();
    final showReset = usedPct >= _resetThreshold && sub.planId != null;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        SizedBox(
          height: 52,
          child: Row(
            children: [
              // 续费当前套餐（R6.4）：有套餐才显示，实心品牌按钮。
              if (!sub.hasNoPlan)
                Expanded(
                  child: FilledButton(
                    onPressed: () => _openPlans(context),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15)),
                    ),
                    child: const Text('续费当前套餐'),
                  ),
                ),
              if (!sub.hasNoPlan) const SizedBox(width: 12),
              // 购买/更改套餐（R6.5/R6.6），描边品牌按钮。
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _openPlans(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.primary,
                    side: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.4), width: 1.6),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15)),
                  ),
                  child: Text(sub.hasNoPlan ? '购买套餐' : '购买 / 更改套餐'),
                ),
              ),
            ],
          ),
        ),
        // 流量重置告警卡（原型 .resetcard，仅 ≥90% 显示）。
        if (showReset) ...[
          const SizedBox(height: 12),
          _ResetCard(pctInt: pctInt, onTap: () => _openReset(context, sub)),
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

/// 流量重置告警卡（原型 .resetcard，仅用量 ≥90% 显示，R6.3）。
class _ResetCard extends StatelessWidget {
  const _ResetCard({required this.pctInt, required this.onTap});

  final int pctInt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 告警色：用主题 error 调和出柔和底（原型 --warn 系）。
    final warn = scheme.error;
    final cardBg = Color.alphaBlend(warn.withValues(alpha: 0.10), scheme.surfaceContainerLowest);
    return Material(
      color: cardBg,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: warn.withValues(alpha: 0.32)),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_rounded, color: warn, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '流量即将用尽（已用 $pctInt%）',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '可购买流量重置包，立即恢复本月可用流量',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                decoration: BoxDecoration(
                  color: warn,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Text(
                  '流量重置',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
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
