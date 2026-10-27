import 'dart:async';

/// Shared by all subscription-service generations using one index database.
/// Only local persistence is serialized; network/decryption stays outside.
class ProfileMutationQueue {
  final _tails = <(String, String), Future<void>>{};
  final _pending = <(String, String), int>{};

  int pendingFor(String flavor, String owner) => _pending[(flavor, owner)] ?? 0;

  bool isBusy(String flavor, String owner) => _tails.containsKey((flavor, owner));

  Future<T> run<T>(String flavor, String owner, Future<T> Function() action) {
    final key = (flavor, owner);
    final previous = _tails[key];
    final released = Completer<void>();
    _tails[key] = released.future;
    _pending[key] = (_pending[key] ?? 0) + 1;
    Future<T> perform() async {
      try {
        if (previous != null) await previous;
        return await action();
      } finally {
        // A failed operation must release the lane without poisoning successors.
        final remaining = _pending[key]! - 1;
        if (remaining == 0) {
          _pending.remove(key);
        } else {
          _pending[key] = remaining;
        }
        released.complete();
        if (identical(_tails[key], released.future)) unawaited(_tails.remove(key));
      }
    }
    return perform();
  }
}
