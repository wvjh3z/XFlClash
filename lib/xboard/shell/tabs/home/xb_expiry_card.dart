/// 首页套餐到期提醒卡（spec form-a / 用户 2026-06-13 决策）。
///
/// **显示条件**（已登录 + 有到期日）：
/// - 剩余 ≤7 天（含不足 1 天显示小时）→ 琥珀提醒卡
/// - 剩余 ≤3 天 / 已过期 → 红色紧急卡
/// - 剩余 >7 天 / 长期有效（expiredAt==null）/ 游客 → 不显示
///
/// 数据源：复用 `userProfileProvider`（订阅同步已在冷启动 + 24h 节流刷新，无需额外网络检测）。
/// 点击「去续费」→ 调 [onTapRenew]（可注入测试回调；生产默认直接打开当前套餐续费页）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import '../../../widgets/xb_plan_notice_card.dart';
import '../../../navigation/plan_navigation.dart';

/// 到期提醒卡。
class XbExpiryCard extends ConsumerWidget {
  const XbExpiryCard({super.key, this.onTapRenew, this.centered = false});

  /// 点「去续费」→ 直接打开续费页（可注入回调）。
  final VoidCallback? onTapRenew;

  /// 桌面态（原型 `.expirecard{width:fit-content;margin:0 auto}`）：按内容宽度收窄并居中，
  /// 不撑满整个内容区（避免横幅过长）。移动端默认 false → 全宽。
  final bool centered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 游客不显示。
    if (ref.watch(authStateProvider) != AuthState.authenticated) {
      return const SizedBox.shrink();
    }
    // 订阅未就绪 / 失败 → 不显示（不打扰；账号卡自己有错误态）。
    final sub = ref.watch(userProfileProvider).asData?.value;
    if (sub == null) return const SizedBox.shrink();

    final expiredAt = sub.expiredAt;
    if (expiredAt == null) return const SizedBox.shrink(); // 长期有效

    final now = DateTime.now();
    final diff = expiredAt.difference(now);
    final expired = !expiredAt.isAfter(now);

    // 未过期且剩余 >7 天（按下取整天数）→ 不显示。剩 7 天 12 小时 → inDays=7 → 显示。
    if (!expired && diff.inDays > 7) return const SizedBox.shrink();

    final urgent = expired || diff <= const Duration(days: 3);

    final (title, desc) = _texts(expired, diff);

    return XbPlanNoticeCard(
      title: title,
      desc: desc,
      icon: expired ? Icons.error_outline : Icons.schedule,
      urgent: urgent,
      actionLabel: '去续费',
      centered: centered,
      onTap: onTapRenew ?? () => openCurrentPlanRenew(context, ref),
    );
  }

  /// 文案：标题 + 描述。
  (String, String) _texts(bool expired, Duration diff) {
    if (expired) {
      return ('套餐已过期', '续费后恢复服务');
    }
    final String dayTxt;
    if (diff < const Duration(days: 1)) {
      final hrs = (diff.inMinutes + 59) ~/ 60; // 向上取整
      dayTxt = '仅剩 ${hrs < 1 ? 1 : hrs} 小时';
    } else {
      dayTxt = '仅剩 ${diff.inDays} 天';
    }
    return ('套餐即将到期 · $dayTxt', '续费当前套餐，避免服务中断');
  }
}
