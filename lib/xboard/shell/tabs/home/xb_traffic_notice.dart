import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/auth_state_provider.dart';
import '../../../providers/user_profile_provider.dart';
import '../../../navigation/plan_navigation.dart';
import '../../../widgets/xb_plan_notice_card.dart';
import '../../../util/format.dart';

/// Use exact byte ratios for thresholds; never round 89.9% into an alert.
int? trafficNoticeLevel(int used, int total) {
  if (total <= 0 || used < 0) return null;
  if (used >= total) return 100;
  if (used * 100 >= total * 95) return 95;
  if (used * 100 >= total * 90) return 90;
  return null;
}

class XbTrafficNotice extends ConsumerWidget {
  const XbTrafficNotice({super.key, this.centered = false});
  final bool centered;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(authStateProvider) != AuthState.authenticated) {
      return const SizedBox.shrink();
    }
    final profile = ref.watch(userProfileProvider);
    if (profile.isLoading || profile.hasError) return const SizedBox.shrink();
    final sub = profile.asData?.value;
    if (sub == null || sub.planId == null) return const SizedBox.shrink();
    final level = trafficNoticeLevel(sub.usedBytes, sub.totalBytes);
    if (level == null) return const SizedBox.shrink();
    // Truncate the displayed percentage so 94.99% is not labelled as 95.0%.
    final percent =
        (sub.usedBytes >= sub.totalBytes
                ? 100.0
                : (sub.usedBytes * 1000 ~/ sub.totalBytes) / 10)
            .toStringAsFixed(1);
    return XbPlanNoticeCard(
      title: '${level == 100 ? '流量已用尽' : '流量将用尽'} · 已用 $percent%',
      desc: level == 100
          ? '查看套餐，及时补充流量'
          : '剩余 ${xbGb(sub.totalBytes - sub.usedBytes)} GB，请留意用量',
      icon: Icons.data_usage,
      urgent: level >= 95,
      actionLabel: '重置流量',
      centered: centered,
      onTap: () => openCurrentTrafficReset(context, ref),
    );
  }
}
