import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_state_provider.dart';
import '../providers/user_profile_provider.dart';
import '../providers/xboard_providers.dart' show bootstrapReadyProvider;
import '../pages/reset_traffic_page.dart';
import '../widgets/xb_feedback.dart' show xbToast;
import '../shell/tabs/shop/xb_shop_navigation.dart';

/// App entry policy, not a purchase restriction imposed by the panel.
const trafficResetEntryPercent = 80;

bool meetsTrafficResetThreshold(int usedBytes, int totalBytes) =>
    totalBytes > 0 &&
    usedBytes >= 0 &&
    usedBytes * 100 >= totalBytes * trafficResetEntryPercent;

/// Browse the shop without opening a purchase confirmation or a checkout.
void openCurrentPlanRenew(BuildContext context, WidgetRef ref) {
  final navigation = XbShopNavigation.maybeOf(context);
  if (navigation == null) return;
  final authenticated = ref.read(authStateProvider) == AuthState.authenticated;
  final ready = authenticated && ref.read(bootstrapReadyProvider);
  final profile = ready ? ref.read(userProfileProvider) : null;
  navigation.onOpen(
    XbShopIntent(
      revision: ref.read(authStateProvider.notifier).sessionRevision,
      authenticated: authenticated,
      planId: profile?.asData?.value.planId,
      waitForProfile: authenticated && (profile == null || profile.isLoading),
    ),
  );
}

void openCurrentTrafficReset(BuildContext context, WidgetRef ref) {
  if (ref.read(authStateProvider) != AuthState.authenticated) return;
  final profile = ref.read(userProfileProvider);
  if (profile.isLoading || profile.hasError) {
    xbToast(context, profile.isLoading ? '正在读取当前套餐，请稍后再试' : '当前套餐资料未更新，请刷新后再试');
    return;
  }
  final sub = profile.asData?.value;
  if (sub == null ||
      sub.planId == null ||
      !meetsTrafficResetThreshold(sub.usedBytes, sub.totalBytes)) {
    return;
  }
  showTrafficResetDialog(
    context,
    ref,
    sub,
    isEligible: (profile) =>
        meetsTrafficResetThreshold(profile.usedBytes, profile.totalBytes),
  );
}
