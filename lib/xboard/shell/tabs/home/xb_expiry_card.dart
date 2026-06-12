/// 首页套餐到期提醒卡（spec form-a / 用户 2026-06-13 决策）。
///
/// **显示条件**（已登录 + 有到期日）：
/// - 剩余 ≤7 天（含不足 1 天显示小时）→ 琥珀提醒卡
/// - 剩余 ≤3 天 / 已过期 → 红色紧急卡
/// - 剩余 >7 天 / 长期有效（expiredAt==null）/ 游客 → 不显示
///
/// 数据源：复用 `userProfileProvider`（订阅同步已在冷启动 + 24h 节流刷新，无需额外网络检测）。
/// 点击「去续费」→ 调 [onTapRenew]（shell 注入，跳「我的」Tab 让用户续费当前套餐）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;

/// 到期提醒卡。
class XbExpiryCard extends ConsumerWidget {
  const XbExpiryCard({super.key, this.onTapRenew});

  /// 点「去续费」→ 跳「我的」Tab（shell 注入）。
  final VoidCallback? onTapRenew;

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
    final scheme = Theme.of(context).colorScheme;
    final t = XbTokens.of(context);
    final accent = urgent ? XbTokens.bad : XbTokens.warn;

    final (title, desc) = _texts(expired, diff);

    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        child: InkWell(
          onTap: onTapRenew,
          borderRadius: BorderRadius.circular(XbTokens.rMd),
          child: Ink(
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                  accent.withValues(alpha: 0.10), scheme.surface),
              border: Border.all(color: accent.withValues(alpha: 0.32)),
              borderRadius: BorderRadius.circular(XbTokens.rMd),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              child: Row(
                children: [
                  // 图标方块
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(XbTokens.rSm),
                    ),
                    child: Icon(
                      expired ? Icons.error_outline : Icons.schedule,
                      size: 19,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 11),
                  // 标题 + 描述
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: t.on,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          desc,
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 去续费按钮
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(XbTokens.rSm),
                    ),
                    child: const Text(
                      '去续费',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
