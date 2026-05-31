/// R10 预警 banner（流量超额 / 余额到期 + F14 游客防误弹）。
///
/// **F14 gate**（design L1467）：调用方先 `authState == authenticated` 再 watch userProfileProvider
/// （游客态不触发 R10「登录已过期」误弹）。本 widget 默认在已登录态渲染。
///
/// a11y：errorContainer / tertiaryContainer 对比度 WCAG AA Large + 深色模式自适应（合规 § D）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_domain_subscription.dart';
import '../providers/user_profile_provider.dart';

/// 预警类型（决定文案 + 配色）。
enum XbWarningKind { trafficLow, expiringSoon, overQuota }

/// 计算订阅需要的预警（无则 null）。优先级：超额 > 流量不足 > 即将到期。
XbWarningKind? computeWarning(
  XbDomainSubscription sub, {
  int expireWarningDays = 3,
  double trafficWarningPercent = 0.1,
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  // 超额（已用 ≥ 总量，且总量 > 0）。
  if (sub.totalBytes > 0 && sub.usedBytes >= sub.totalBytes) {
    return XbWarningKind.overQuota;
  }
  // 流量不足（剩余 < 阈值%）。
  if (sub.totalBytes > 0) {
    final remainRatio = sub.remainingBytes / sub.totalBytes;
    if (remainRatio <= trafficWarningPercent) return XbWarningKind.trafficLow;
  }
  // 即将到期。
  final exp = sub.expiredAt;
  if (exp != null) {
    final days = exp.difference(t).inDays;
    if (days >= 0 && days <= expireWarningDays) return XbWarningKind.expiringSoon;
  }
  return null;
}

/// R10 预警 banner —— 在已登录态使用（调用方 gate authState，F14）。
class WarningBanner extends ConsumerWidget {
  const WarningBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userProfileProvider);
    final sub = async.asData?.value;
    if (sub == null) return const SizedBox.shrink();
    final kind = computeWarning(sub);
    if (kind == null) return const SizedBox.shrink();
    return _BannerBody(kind: kind);
  }
}

class _BannerBody extends StatelessWidget {
  const _BannerBody({required this.kind});
  final XbWarningKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUrgent = kind == XbWarningKind.overQuota || kind == XbWarningKind.expiringSoon;
    final bg = isUrgent ? scheme.errorContainer : scheme.tertiaryContainer;
    final fg = isUrgent ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(_icon, size: 18, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)),
          ),
        ],
      ),
    );
  }

  IconData get _icon => switch (kind) {
        XbWarningKind.overQuota => Icons.data_usage_rounded,
        XbWarningKind.trafficLow => Icons.warning_amber_rounded,
        XbWarningKind.expiringSoon => Icons.schedule_rounded,
      };

  String get _text => switch (kind) {
        XbWarningKind.overQuota => '流量已用尽，请购买流量包或等待重置',
        XbWarningKind.trafficLow => '流量即将用尽，建议及时续费',
        XbWarningKind.expiringSoon => '订阅即将到期，请续费以免中断',
      };
}
