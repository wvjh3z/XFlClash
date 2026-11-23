import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/network_recovery_provider.dart';

export '../providers/network_recovery_provider.dart' show xbIsRecoverableReadError;

/// Register during build. A new confirmed recovery epoch is an opportunity
/// to reload, not a command to invalidate every page or replay a mutation.
/// The caller owns the failed-read, session and single-flight checks.
void xbListenForReadRecovery(
  BuildContext context,
  WidgetRef ref,
  VoidCallback onRecovery, {
  bool active = true,
}) {
  final visible = active && TickerMode.valuesOf(context).enabled;
  final route = ModalRoute.of(context);
  ref.listen<int>(networkRecoveryProvider, (previous, next) {
    if (!visible || !context.mounted || next <= (previous ?? 0)) return;
    if (route != null && !route.isCurrent) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    onRecovery();
  });
}
