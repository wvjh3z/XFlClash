import 'package:flutter/widgets.dart';

/// A verified recovery may arrive while the original read is still settling.
/// Recheck visibility and owner after the await, before issuing a second GET.
Future<void> recoverCommerceRead({
  required BuildContext context,
  required bool Function() current,
  required Future<void> Function() retryIfFailed,
  Future<dynamic>? pending,
}) async {
  if (pending != null) {
    try { await pending; } catch (_) { /* The owner classifies the failure. */ }
  }
  if (!context.mounted || !current() || ModalRoute.of(context)?.isCurrent == false ||
      !TickerMode.valuesOf(context).enabled) {
    return;
  }
  final life = WidgetsBinding.instance.lifecycleState;
  if (life != null && life != AppLifecycleState.resumed) return;
  await retryIfFailed();
}
