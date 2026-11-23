import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import '../models/xb_domain_error.dart';

/// A guest-config probe succeeded in a new verification window. Not an
/// interface-change notification, permission to replay a write, or login.
final networkRecoveryProvider =
    NotifierProvider<NetworkRecoveryNotifier, int>(NetworkRecoveryNotifier.new);
final verifiedRouteEpochProvider = NotifierProvider<VerifiedRouteEpoch, int>(VerifiedRouteEpoch.new);
class VerifiedRouteEpoch extends Notifier<int> {
  @override
  int build() => 0;
  void advance() => state++;
}

class NetworkRecoveryNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void publish({bool routeChanged = true}) {
    if (routeChanged) ref.read(verifiedRouteEpochProvider.notifier).advance();
    state++;
  }
}

/// Only read failures can be passed here. Never infer that a write wasn't sent.
bool xbIsRecoverableReadError(Object? error) => switch (error) {
  XbNetwork() || TimeoutException() => true,
  XbServer(:final httpStatusCode) => const {
    500,
    502,
    503,
    504,
  }.contains(httpStatusCode),
  _ => false,
};

/// Register before starting a read. A verified generation can precede its
/// late network error; in that case consume the same event after settlement.
void Function(Object error) retryReadOnRecovery(Ref ref, {bool Function()? current}) {
  final initial = ref.read(networkRecoveryProvider);
  var failed = false;
  ref.listen(networkRecoveryProvider, (_, next) {
    if (failed && next != initial && (current?.call() ?? true)) ref.invalidateSelf();
  });
  return (error) {
    failed = xbIsRecoverableReadError(error);
    if (failed && ref.mounted && ref.read(networkRecoveryProvider) != initial) {
      scheduleMicrotask(() { if (ref.mounted && (current?.call() ?? true)) ref.invalidateSelf(); });
    }
  };
}
