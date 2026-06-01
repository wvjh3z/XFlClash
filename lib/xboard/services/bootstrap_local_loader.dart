/// Bootstrap 同步本地加载（DD-17 render-first，零网络，runApp 前）。
///
/// 优先级（R15.B / B-extra）：本地缓存密文 → 出厂 fallback 资产密文 → 双双损坏返 null。
/// 全程仅磁盘读 + GCM 解密，无网络 IO。返 null → bootstrapReadyProvider=false（F15 banner）。
///
/// 缓存 key DD-22 v1（`xb_bootstrap_cache_v1`），只存外层 envelope **密文**（R15.D.25/D.28）。
/// 反序列化失败 → delete + 走 fallback。永不抛（Property 1）。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/bootstrap_constants.dart';
import '../models/bootstrap_envelope.dart';
import '../models/bootstrap_payload.dart';
import 'bootstrap_decryptor.dart';
import 'sentry_bootstrap.dart';

/// 本地 Bootstrap 加载结果（payload + 来源，DD-23 envelope_source tag）。
enum BootstrapLocalSource { cache, fallbackAsset, none }

/// DD-23 `bootstrap.envelope_source` tag 值映射（5.7.2）。远端拉取成功用 `'remote'`（见编排层）。
extension BootstrapLocalSourceTag on BootstrapLocalSource {
  String get tagValue => switch (this) {
        BootstrapLocalSource.cache => 'cache',
        BootstrapLocalSource.fallbackAsset => 'fallback_asset',
        BootstrapLocalSource.none => 'none',
      };
}

class BootstrapLocalResult {
  const BootstrapLocalResult(this.payload, this.source);
  final BootstrapPayload? payload;
  final BootstrapLocalSource source;
}

class BootstrapLocalLoader {
  BootstrapLocalLoader({
    required BootstrapDecryptor decryptor,
    SharedPreferences? prefs,
    Future<String> Function(String)? assetLoader,
  })  : _decryptor = decryptor,
        _injectedPrefs = prefs,
        _assetLoader = assetLoader ?? rootBundle.loadString;

  final BootstrapDecryptor _decryptor;
  final SharedPreferences? _injectedPrefs;
  final Future<String> Function(String) _assetLoader;

  Future<SharedPreferences> get _prefs async =>
      _injectedPrefs ?? await SharedPreferences.getInstance();

  /// 同步本地加载（缓存 → fallback → null）。
  Future<BootstrapLocalResult> loadLocal() async {
    // 1. 本地缓存密文。
    final cached = await _tryCache();
    if (cached != null) {
      SentryBootstrap.tagBootstrap(
          envelopeSource: BootstrapLocalSource.cache.tagValue);
      return BootstrapLocalResult(cached, BootstrapLocalSource.cache);
    }
    // 2. 出厂 fallback 资产密文（随包必带 R15.B-extra.9）。
    final fallback = await _tryFallbackAsset();
    if (fallback != null) {
      SentryBootstrap.tagBootstrap(
          envelopeSource: BootstrapLocalSource.fallbackAsset.tagValue);
      return BootstrapLocalResult(fallback, BootstrapLocalSource.fallbackAsset);
    }
    // 3. 双双损坏 → null（F15 处理）。
    SentryBootstrap.tagBootstrap(
        envelopeSource: BootstrapLocalSource.none.tagValue);
    return const BootstrapLocalResult(null, BootstrapLocalSource.none);
  }

  /// 写缓存（远端拉取成功后，只存密文，R15.D.25）。
  Future<void> writeCache(BootstrapEnvelope env) async {
    try {
      final prefs = await _prefs;
      await prefs.setString(kBootstrapCacheKey, jsonEncode(env.toJson()));
    } catch (_) {
      // 写缓存失败不影响运行（Property 1）。
    }
  }

  Future<BootstrapPayload?> _tryCache() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(kBootstrapCacheKey);
      if (raw == null) return null;
      final env = BootstrapEnvelope.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      final result = await _decryptor.decryptAndValidate(env);
      if (result.isSuccess) return result.payload;
      // 解密失败（key 变更 / 数据损坏）→ delete（DD-22 反序列化失败兜底）。
      await prefs.remove(kBootstrapCacheKey);
      return null;
    } catch (_) {
      try {
        (await _prefs).remove(kBootstrapCacheKey);
      } catch (_) {}
      return null;
    }
  }

  Future<BootstrapPayload?> _tryFallbackAsset() async {
    try {
      final raw = await _assetLoader(kBootstrapFallbackAsset);
      final env = BootstrapEnvelope.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      final result = await _decryptor.decryptAndValidate(env);
      return result.payload; // null if 损坏
    } catch (_) {
      return null;
    }
  }
}
