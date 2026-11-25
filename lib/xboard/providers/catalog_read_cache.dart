import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_state_provider.dart';
import 'xboard_providers.dart';

/// A process-local cache of display data only. Replacing credentials, service
/// or endpoint discards the owner rather than reusing another panel's data.
final catalogReadCacheProvider = Provider<CatalogReadCache>((ref) {
  ref.watch(authStateProvider);
  ref.watch(apiEndpointProvider);
  ref.watch(xboardServiceProvider);
  final clock = Stopwatch()..start();
  return CatalogReadCache(() => clock.elapsed);
});

class CatalogReadCache {
  CatalogReadCache(this._now);
  final Duration Function() _now;
  final _entries = <Object, ({Duration until, Object value})>{};
  static const catalogTtl = Duration(hours: 24);
  static const shareLinkTtl = Duration(minutes: 5);

  bool fresh(Object key) {
    final entry = _entries[key];
    return entry != null && _now() < entry.until;
  }

  T? lookup<T>(Ref ref, Object key) {
    if (!ref.isRefresh && fresh(key)) return _entries[key]!.value as T;
    _entries.remove(key);
    return null;
  }

  T remember<T extends Object>(Ref ref, Object key, T value, {Duration ttl = catalogTtl}) {
    if (!ref.mounted) return value;
    final now = _now();
    _entries.removeWhere((_, e) => now >= e.until);
    if (_entries.length >= 64) _entries.remove(_entries.keys.first);
    _entries[key] = (until: now + ttl, value: value);
    return value;
  }
}
