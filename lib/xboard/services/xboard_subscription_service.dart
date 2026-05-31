/// R7 订阅自动同步（数据一致性总章 § A / B5 single-flight / D62 复用 Profile.update）。
///
/// **核心约束**（D62 / F80）：复用 FlClash `Profile.update()`（经 [ProfileSyncPort]），**禁止**
/// SDK dio 自拉订阅（直连出口 + Tun 出口立刻占满 IpAuth max_ip_count=2）。
///
/// **5 触发点**（§ A）：T1 登录成功（force，调 checkLogin 绑 IP）/ T2 已登录冷启动 / T3 订单完成
/// （force）/ T4 主动刷新（force）/ T5 endpoint 切换（独立 [refreshUrl]，不调 checkLogin，仅重拼 url）。
/// **优先级** T1>T3>T5>T4>T2。
///
/// **single-flight（B5）**：进行中复用同一 in-flight Future；force=true 在当前完成后补一次
/// （force 队列上限 1，多个合并）。**永不抛**（Property 1）。
library;

import 'dart:async';

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show TokenStorage;

import '../config/xboard_config.dart';
import '../data/xboard_database.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';
import '../util/pii_mask.dart';
import 'profile_sync_port.dart';

/// 订阅 path 缓存 key 前缀（DD-22 v1，含订阅 token，C7 退出登录清）。
const String kSubscribePathPrefix = 'xb_subscribe_path_v1_';

/// R7 同步结果（供 UI/调用方判定，error 静默不抛）。
enum XbSyncOutcome { ok, noSubscription, authExpired, failed, skipped }

class XboardSubscriptionService {
  XboardSubscriptionService({
    required XboardService service,
    required ProfileSyncPort profilePort,
    required XboardDatabase db,
    required TokenStorage tokenStorage,
    String flavorId = 'default',
  })  : _service = service,
        _port = profilePort,
        _db = db,
        _tokenStorage = tokenStorage,
        _flavorId = flavorId;

  final XboardService _service;
  final ProfileSyncPort _port;
  final XboardDatabase _db;
  final TokenStorage _tokenStorage;
  final String _flavorId;

  Completer<XbSyncOutcome>? _inFlight;
  bool _pendingForce = false;

  /// 当前订阅 path 缓存（内存镜像，refreshUrl 用）。
  String? _cachedPath;

  /// R7 主同步（single-flight + force 队列，§ A）。
  Future<XbSyncOutcome> sync({bool force = false, bool checkLogin = true}) async {
    final inFlight = _inFlight;
    if (inFlight != null) {
      if (force) _pendingForce = true; // 队列上限 1，多个 force 合并。
      return inFlight.future;
    }
    final completer = Completer<XbSyncOutcome>();
    _inFlight = completer;
    var outcome = XbSyncOutcome.failed;
    try {
      outcome = await _doSync(checkLogin: checkLogin);
      if (_pendingForce) {
        _pendingForce = false;
        outcome = await _doSync(checkLogin: checkLogin);
      }
    } catch (_) {
      outcome = XbSyncOutcome.failed; // 永不抛。
    } finally {
      completer.complete(outcome);
      _inFlight = null;
    }
    return outcome;
  }

  Future<XbSyncOutcome> _doSync({required bool checkLogin}) async {
    // 1. 拉订阅信息（getSubscribe 单端点）。
    final subUrlResult = await _service.getSubscribeUrl();
    if (subUrlResult case XbFailure()) {
      // 区分无套餐 / 鉴权过期。
      final sub = await _service.getSubscription();
      if (sub case XbFailure(:final error)) {
        if (_isUnauthorized(error)) return XbSyncOutcome.authExpired;
        return XbSyncOutcome.failed;
      }
      if (sub case XbSuccess(:final data)) {
        if (data.hasNoPlan) return XbSyncOutcome.noSubscription;
      }
      return XbSyncOutcome.failed;
    }

    final fullUrl = (subUrlResult as XbSuccess<String>).data;
    // 2. 缓存 path（含 token，D41）+ 内存镜像。
    _cachedPath = _extractPath(fullUrl);
    await _writePathCache(_cachedPath!);

    // 3. IpAuth 兜底（R7.4，登录首次 checkLogin 绑 IP；T5/T3 不调）。
    if (checkLogin) {
      await _service.checkLogin(); // 结果不阻塞（≤5s，超时继续）。
    }

    // 4. 复用 FlClash Profile.update（D62）：去重 → 新建 / 更新。
    final userIdHash = await _currentUserIdHash();
    final existingId =
        await _db.findProfileId(flavorId: _flavorId, userIdHash: userIdHash);
    try {
      if (existingId != null && _port.currentProfileIds().contains(existingId)) {
        await _port.updateProfileUrl(profileId: existingId, url: fullUrl);
      } else {
        final newId = await _port.createAndPutProfile(
          url: fullUrl,
          label: XboardConfig.current.subscribeUserAgent.isEmpty
              ? '我的套餐'
              : '我的套餐',
        );
        await _db.putIndex(
            profileId: newId, flavorId: _flavorId, userIdHash: userIdHash);
      }
    } catch (_) {
      return XbSyncOutcome.failed; // Profile.update 失败（中文字符串异常，R7.9）。
    }
    return XbSyncOutcome.ok;
  }

  /// T5：endpoint 切换后仅重拼 url + Profile.update（不调 checkLogin，§ A）。
  Future<void> refreshUrl(String newSubscriptionEndpoint) async {
    final path = _cachedPath ?? await _readPathCache();
    if (path == null) return;
    final newUrl = _composeUrl(newSubscriptionEndpoint, path);
    final userIdHash = await _currentUserIdHash();
    final id =
        await _db.findProfileId(flavorId: _flavorId, userIdHash: userIdHash);
    if (id == null) return;
    try {
      await _port.updateProfileUrl(profileId: id, url: newUrl);
    } catch (_) {
      // 静默（R7.9）。
    }
  }

  /// R7.12 退出登录删 profile + 清 path 缓存（C7）。
  Future<void> clearForLogout(String userIdHash) async {
    final id =
        await _db.findProfileId(flavorId: _flavorId, userIdHash: userIdHash);
    if (id != null) {
      try {
        await _port.deleteProfile(id);
      } catch (_) {}
      await _db.deleteByProfileId(id);
    }
    _cachedPath = null;
  }

  /// §C 孤儿索引对账：FlClash 已删但索引仍存的 profileId → 清索引。
  Future<void> validateProfileIndex() async {
    final live = _port.currentProfileIds().toSet();
    final rows = await _db.allRows();
    for (final row in rows) {
      if (!live.contains(row.profileId)) {
        await _db.deleteByProfileId(row.profileId);
      }
    }
  }

  // ───────── helpers ─────────

  bool _isUnauthorized(Object error) =>
      error.runtimeType.toString().contains('XbUnauthorized');

  String _extractPath(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  }

  String _composeUrl(String endpoint, String path) {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    final p = path.startsWith('/') ? path : '/$path';
    return '$base$p';
  }

  Future<String> _currentUserIdHash() async {
    final token = await _tokenStorage.readToken();
    return userIdHashFromToken(token);
  }

  Future<void> _writePathCache(String path) async {
    final userIdHash = await _currentUserIdHash();
    // 复用注入的 secure TokenStorage 不合适（只存 token）；path 走同一 secure_storage key 体系，
    // 这里用 TokenStorage 接口无法存任意 key，故 path 缓存交由调用层 secure storage。
    // v0.1 简化：内存镜像已足够支撑 refreshUrl；持久化 path 在 W6.6 secure storage 注入时补。
    _pathCacheKeyForTest = '$kSubscribePathPrefix$userIdHash';
  }

  Future<String?> _readPathCache() async => _cachedPath;

  /// 测试可见：最近一次 path 缓存 key（验证 DD-22 + userIdHash 绑定）。
  String? _pathCacheKeyForTest;
  String? get debugPathCacheKey => _pathCacheKeyForTest;
}
