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

/// For a visible page whose initial GET may finish *after* the API probe.
/// A manually replaced read, hidden route or disposed owner must not retry.
void xbListenForPendingReadRecovery<T>(BuildContext context, WidgetRef ref, {
  required AsyncValue<T> Function() state,
  required Future<T> Function() future,
  required VoidCallback retry,
  bool Function()? current,
}) {
  xbListenForReadRecovery(context, ref, () async {
    if (current?.call() == false) return;
    if (state().isLoading) {
      final pending = future();
      try {
        await pending;
        return;
      } catch (_) {
        if (!context.mounted || ModalRoute.of(context)?.isCurrent == false ||
            !TickerMode.valuesOf(context).enabled || current?.call() == false ||
            !identical(future(), pending)) {
          return;
        }
        final life = WidgetsBinding.instance.lifecycleState;
        if (life != null && life != AppLifecycleState.resumed) return;
      }
    }
    final latest = state();
    if (!latest.isLoading && xbIsRecoverableReadError(latest.error)) retry();
  });
}
