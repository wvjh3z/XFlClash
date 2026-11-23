import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/xboard_subscription_service.dart';
import 'auth_state_provider.dart';
import '../models/xb_domain_subscription.dart';

typedef SubscriptionSyncStatus = ({int revision, XbSyncOutcome outcome});

enum NodeReadPhase { idle, loading, failed }
final nodeReadPhaseProvider = NotifierProvider<NodeReadPhaseNotifier, NodeReadPhase>(NodeReadPhaseNotifier.new);
class NodeReadPhaseNotifier extends Notifier<NodeReadPhase> {
  @override
  NodeReadPhase build() { ref.watch(authStateProvider); return NodeReadPhase.idle; }
  void set(NodeReadPhase phase) => state = phase;
}

/// Shared meaningful completion status for both manual and background sync.
final subscriptionSyncStatusProvider =
    NotifierProvider<SubscriptionSyncStatusNotifier, SubscriptionSyncStatus?>(
      SubscriptionSyncStatusNotifier.new,
    );

class SubscriptionSyncStatusNotifier extends Notifier<SubscriptionSyncStatus?> {
  int completion = 0;
  @override
  SubscriptionSyncStatus? build() {
    ref.listen(authStateProvider, (_, _) => state = null);
    return null;
  }

  void publish(XbSyncOutcome outcome, int revision) {
    if (ref.read(authStateProvider.notifier).sessionRevision != revision) return;
    ref.read(nodeReadPhaseProvider.notifier).set(outcome == XbSyncOutcome.failed ? NodeReadPhase.failed : NodeReadPhase.idle);
    if (outcome == XbSyncOutcome.failed || outcome == XbSyncOutcome.skipped) return;
    completion++;
    state = (revision: revision, outcome: outcome);
  }

  void clear() => state = null;
}

/// Keep the last *denial*, never a grant, while rechecking a blocking profile.
/// Survives Tab disposal and errors. Only a fresh successful profile can lift it.
final nodeProfileHoldProvider =
    NotifierProvider<NodeProfileHold, XbDomainSubscription?>(NodeProfileHold.new);

class NodeProfileHold extends Notifier<XbDomainSubscription?> {
  int? _revision;

  @override
  XbDomainSubscription? build() {
    ref.watch(authStateProvider);
    return null;
  }

  void hold(XbDomainSubscription denial) {
    _revision = ref.read(authStateProvider.notifier).sessionRevision;
    state = denial;
  }

  /// Called by the owner-validated online profile request, not by the
  /// page that happened to initiate it. Never change the server sync status.
  void acceptFresh(int revision, XbDomainSubscription fresh) {
    if (state == null || revision != _revision || fresh.planId == null ||
        ref.read(authStateProvider) != AuthState.authenticated ||
        ref.read(authStateProvider.notifier).sessionRevision != revision) {
      return;
    }
    final expired = fresh.expiredAt != null && !fresh.expiredAt!.isAfter(DateTime.now());
    final exhausted = fresh.totalBytes > 0 && fresh.usedBytes >= fresh.totalBytes;
    state = expired || exhausted ? fresh : null;
  }
  XbDomainSubscription? forRevision(int revision) =>
      revision == _revision ? state : null;
}
