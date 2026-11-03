import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_state_provider.dart';
import '../providers/user_profile_provider.dart';
import '../pages/plan_detail_page.dart';
import '../pages/plan_list_page.dart';
import '../pages/reset_traffic_page.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush;

/// Read authentication and the account at click time, not the last painted frame.
void openCurrentPlanRenew(BuildContext context, WidgetRef ref) {
  if (ref.read(authStateProvider) != AuthState.authenticated) return;
  final profile = ref.read(userProfileProvider);
  if (profile.isLoading || profile.hasError) return;
  final sub = profile.asData?.value;
  if (sub == null) return;
  final id = sub.planId;
  xbPush(
    context,
    id == null ? const PlanListPage() : PlanRenewLoader(planId: id),
    brandColor: xbBrandColor(),
  );
}

void openCurrentTrafficReset(BuildContext context, WidgetRef ref) {
  if (ref.read(authStateProvider) != AuthState.authenticated) return;
  final profile = ref.read(userProfileProvider);
  if (profile.isLoading || profile.hasError) return;
  final sub = profile.asData?.value;
  if (sub == null ||
      sub.planId == null ||
      sub.totalBytes <= 0 ||
      sub.usedBytes < 0 ||
      sub.usedBytes * 100 < sub.totalBytes * 90) {
    return;
  }
  xbPush(
    context,
    ResetTrafficPage(planId: sub.planId!, planName: sub.planName),
    brandColor: xbBrandColor(),
  );
}
