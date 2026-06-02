/// R6 账号信息卡（XbDomainSubscription + R6.8 公式 / design L599-620）。
///
/// **数据源**：`userProfileProvider`（调反腐层 `getSubscription()` 单端点 D27）。
/// **F14 防御**：调用方先 gate `authState == authenticated` 再 watch（游客不触发，避免 R10 误弹）。
///
/// 字段（R6.8）：mask(email) / 套餐名 / 已用·总流量（GB）/ 到期 / 流量重置 / 数据时效。
/// 状态：loading → 占位；error → XbDomainError 分流（XboardStateView）；success → 卡片。
/// a11y：textScaleFactor 1.5/2.0 不溢出（Wrap + Flexible）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_domain_error.dart';
import '../models/xb_domain_subscription.dart';
import '../pages/reset_traffic_page.dart';
import '../providers/user_profile_provider.dart';

/// 账号信息卡。需在已登录态下使用（调用方 gate authState，F14）。
class AccountInfoCard extends ConsumerWidget {
  const AccountInfoCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userProfileProvider);
    return async.when(
      loading: () => const _CardShell(child: Center(child: CircularProgressIndicator())),
      error: (e, _) => _CardShell(
        child: _ErrorView(
          error: e is XbDomainError ? e : XbDomainError.unexpected('userProfile', e.toString()),
          onRetry: () => ref.invalidate(userProfileProvider),
        ),
      ),
      data: (sub) => _CardShell(child: _SubscriptionView(sub: sub)),
    );
  }
}

/// 卡片外壳（圆角 + 内边距，统一外观）。
class _CardShell extends StatelessWidget {
  const _CardShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 120),
          child: child,
        ),
      ),
    );
  }
}

class _SubscriptionView extends StatelessWidget {
  const _SubscriptionView({required this.sub});
  final XbDomainSubscription sub;

  static const _gb = 1024 * 1024 * 1024;

  /// 触发流量重置包提示的用量阈值（≥90% 已用，与 R10 trafficWarningPercent=0.1 对齐）。
  static const _resetPromptThreshold = 0.9;

  String _fmtGb(int bytes) => '${(bytes / _gb).toStringAsFixed(1)} GB';

  /// 是否提示购买流量重置包：有套餐（planId 非空 + 有总量）且已用 ≥ 90%。
  bool _shouldPromptReset(double usedRatio) =>
      sub.planId != null && sub.totalBytes > 0 && usedRatio >= _resetPromptThreshold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final usedRatio =
        sub.totalBytes > 0 ? (sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头部：邮箱（脱敏）+ 套餐名
        Row(
          children: [
            CircleAvatar(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              child: const Icon(Icons.person_outline_rounded),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sub.email,
                      style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  Text(sub.planName ?? '未购买套餐',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // 流量进度
        _trafficSection(context, usedRatio),
        // 流量用量 ≥ 90%（含超额）且有套餐 → 提示购买流量重置包（R10 / 用户需求）。
        if (_shouldPromptReset(usedRatio))
          _ResetTrafficPrompt(planId: sub.planId!, planName: sub.planName),
        const SizedBox(height: 16),
        // 到期 / 重置 行
        _InfoRow(
          icon: Icons.event_outlined,
          label: '套餐到期',
          value: _expiryText(),
        ),
        _InfoRow(
          icon: Icons.refresh_rounded,
          label: '流量重置',
          value: _resetText(),
        ),
      ],
    );
  }

  Widget _trafficSection(BuildContext context, double ratio) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final overQuota = sub.totalBytes > 0 && sub.usedBytes >= sub.totalBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('流量', style: text.bodyMedium),
            Flexible(
              child: Text(
                '${_fmtGb(sub.usedBytes)} / ${_fmtGb(sub.totalBytes)}',
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            color: overQuota ? scheme.error : scheme.primary,
          ),
        ),
        if (overQuota) ...[
          const SizedBox(height: 6),
          Text(_overQuotaText(),
              style: text.bodySmall?.copyWith(color: scheme.error)),
        ],
      ],
    );
  }

  String _expiryText() {
    final e = sub.expiredAt;
    if (e == null) return '长期有效';
    final days = e.difference(DateTime.now()).inDays;
    final d = '${e.year}-${e.month.toString().padLeft(2, '0')}-${e.day.toString().padLeft(2, '0')}';
    return days >= 0 ? '$d（剩余 $days 天）' : '$d（已过期）';
  }

  String _resetText() {
    final r = sub.nextResetAt;
    if (r == null) return '流量套餐 / 不重置';
    final diff = r.difference(DateTime.now());
    if (diff.isNegative) return '即将重置';
    final days = diff.inDays;
    final hours = diff.inHours % 24;
    return '距下次重置 $days 天 $hours 小时';
  }

  String _overQuotaText() {
    final r = sub.nextResetAt;
    if (r == null) return '流量已用尽';
    final diff = r.difference(DateTime.now());
    if (diff.isNegative) return '流量已超额，即将重置';
    return '流量已超额，等待 ${diff.inHours % 24} 时 ${diff.inMinutes % 60} 分重置';
  }
}

/// 流量用量 ≥90% 时的「购买流量重置包」提示条（账号卡内，紧贴流量进度下方）。
class _ResetTrafficPrompt extends StatelessWidget {
  const _ResetTrafficPrompt({required this.planId, this.planName});
  final int planId;
  final String? planName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 20, color: scheme.error),
            const SizedBox(width: 10),
            Expanded(
              child: Text('流量即将用尽，可购买流量重置包恢复用量',
                  style: text.bodySmall
                      ?.copyWith(color: scheme.onErrorContainer)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ResetTrafficPage(planId: planId, planName: planName),
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: scheme.error,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('购买'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          Text(label,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          // value 占满剩余空间 + 右对齐 + 允许换行（不截断，空间够时单行显示）。
          Expanded(
            child: Text(value,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                textAlign: TextAlign.right,
                softWrap: true),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final XbDomainError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off_rounded, color: scheme.onSurfaceVariant, size: 36),
        const SizedBox(height: 8),
        Text(
          error.message.isNotEmpty ? error.message : '获取账号信息失败',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('重试'),
        ),
      ],
    );
  }
}
