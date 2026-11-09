import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/xboard_subscription_service.dart';
import 'auth_state_provider.dart';

typedef SubscriptionSyncStatus = ({int revision, XbSyncOutcome outcome});

/// Shared meaningful completion status for both manual and background sync.
final subscriptionSyncStatusProvider =
    NotifierProvider<SubscriptionSyncStatusNotifier, SubscriptionSyncStatus?>(
      SubscriptionSyncStatusNotifier.new,
    );

class SubscriptionSyncStatusNotifier extends Notifier<SubscriptionSyncStatus?> {
  @override
  SubscriptionSyncStatus? build() {
    ref.listen(authStateProvider, (_, _) => state = null);
    return null;
  }

  void publish(XbSyncOutcome outcome, int revision) {
    if (ref.read(authStateProvider.notifier).sessionRevision != revision) return;
    if (outcome == XbSyncOutcome.failed || outcome == XbSyncOutcome.skipped) return;
    state = (revision: revision, outcome: outcome);
  }

  void clear() => state = null;
}
