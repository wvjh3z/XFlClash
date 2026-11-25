import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/xboard_config.dart';
import '../models/plan_item.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_tutorial.dart';
import 'auth_state_provider.dart';
import 'catalog_read_cache.dart';
import 'network_recovery_provider.dart';
import 'xboard_providers.dart';

// Only these display models are serialized. Never store credentials or checkout state.
typedef JsonMap = Map<String, dynamic>;
typedef SnapshotCodec<T> = ({Object Function(T) encode, T Function(dynamic) decode});

final SnapshotCodec<List<PlanItem>> planSnapshots = (
  encode: (plans) => [for (final p in plans) {
    'id': p.id, 'name': p.name, 'description': p.description, 'gb': p.transferEnableGb,
    'renewable': p.renewable, 'prices': [for (final price in p.prices)
      [price.period.name, price.amountYuan]],
  }],
  decode: (rows) => [for (final p in (rows as List).cast<JsonMap>()) PlanItem(
    id: p['id'], name: p['name'], description: p['description'], transferEnableGb: p['gb'],
    renewable: p['renewable'], prices: [for (final price in p['prices'])
      PricePlan(period: XbPlanPeriod.values.byName(price[0]), amountYuan: (price[1] as num).toDouble())],
  )],
);

final SnapshotCodec<List<XbTutorial>> tutorialSnapshots = (
  encode: (items) => [for (final a in items)
    [a.id, a.title, a.updatedAt.millisecondsSinceEpoch, a.requiresIpPlan]],
  decode: (rows) => [for (final a in rows as List) XbTutorial(id: a[0], title: a[1],
    updatedAt: DateTime.fromMillisecondsSinceEpoch(a[2]), requiresIpPlan: a[3])],
);

final SnapshotCodec<XbTutorialDetail> articleSnapshots = (
  encode: (a) => [a.id, a.title, a.updatedAt.millisecondsSinceEpoch, a.requiresIpPlan, a.body, a.resourceBase],
  decode: (a) => XbTutorialDetail(id: a[0], title: a[1],
    updatedAt: DateTime.fromMillisecondsSinceEpoch(a[2]), requiresIpPlan: a[3], body: a[4], resourceBase: a[5]),
);

const _prefix = 'xb_display_v1_';
final displaySnapshotKeyProvider = Provider<String?>((ref) {
  final auth = ref.watch(authStateProvider);
  final owner = switch (auth) {
    AuthState.authenticated => ref.read(authStateProvider.notifier).displayCacheOwner,
    AuthState.unauthenticated => 'guest',
    _ => null,
  };
  final panel = ref.watch(shopPanelScopeProvider);
  if (owner == null || panel == '[""]') return null;
  return '$_prefix${sha256.convert(utf8.encode(jsonEncode(
    [XboardConfig.current.flavorId, panel, owner],
  )))}';
});

/// Fresh hits carry only their remaining lifetime into memory. On a stale
/// hit, publish the snapshot for a frame before starting a normal forced read.
Future<T> readDisplaySnapshot<T extends Object>(Ref ref, CatalogReadCache cache,
    Object memoryKey, String kind, SnapshotCodec<T> codec, Future<T> Function() fetch) async {
  final scope = ref.watch(displaySnapshotKeyProvider);
  final memory = cache.lookup<T>(ref, memoryKey);
  if (memory != null) return memory;
  final partition = kind == 'plans' ? '' : sha256.convert(utf8.encode(ref.watch(apiEndpointProvider))).toString();
  final key = '${scope}_${partition}_$kind';
  SharedPreferences? prefs;
  if (scope != null) {
    try {
      prefs = await SharedPreferences.getInstance();
      if (ref.mounted && !ref.isRefresh) {
        final raw = prefs.getString(key);
        if (raw != null) {
          final snapshot = jsonDecode(raw) as List;
          final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(snapshot[0]));
          final value = codec.decode(snapshot[1]);
          if (!age.isNegative && age < CatalogReadCache.catalogTtl) {
            return await cache.remember(ref, memoryKey, value, ttl: CatalogReadCache.catalogTtl - age);
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ref.mounted) ref.invalidateSelf();
          });
          WidgetsBinding.instance.ensureVisualUpdate();
          return value;
        }
      }
    } catch (_) { /* Missing storage or incompatible snapshot: use the service. */ }
  }
  if (!ref.mounted) throw StateError('Display read no longer active');
  late final T value;
  try {
    value = await fetch();
  } catch (error) {
    if (ref.mounted && prefs != null && !xbIsRecoverableReadError(error)) {
      try { await prefs.remove(key); } catch (_) {}
    }
    rethrow;
  }
  if (ref.mounted && prefs != null) {
    try {
      final encoded = jsonEncode([DateTime.now().millisecondsSinceEpoch, codec.encode(value)]);
      if (utf8.encode(encoded).length <= 512 * 1024) {
        final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
        if (!keys.contains(key) && keys.length >= 32) await prefs.remove(keys.first);
        if (ref.mounted) await prefs.setString(key, encoded);
      } else {
        await prefs.remove(key);
      }
    } catch (_) { /* Storage is optional; return the successful network read. */ }
  }
  return cache.remember(ref, memoryKey, value);
}
