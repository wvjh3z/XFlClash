/// R7/R4.6 订阅自动同步（数据一致性总章 § A / B5 single-flight / v0.2 R4 文件化加密订阅）。
///
/// **v0.2 R4 重构**（取代 v0.1 的「复用 FlClash `Profile.update` 拉 URL」D62 方案）：SDK 自拉
/// 加密订阅密文 → 解密 → 明文 ClashMeta YAML 字节 → 写 **file 型 profile** 喂 FlClash core。
/// 链路：`getSubscribeUrl()`（拿带 token 的原订阅 URL）→ [EncryptedSubscriptionService.fetchWithFailOver]
/// （按竞速候选 host 串行 failOver 拉 + 解密，R4.1/R4.2）→ [ProfileSyncPort.putFileProfile]
/// （`Profile.saveFile` 写明文文件 + 通知 core 重载，零改上游）。
///
/// **不再调 checkLogin**（用户 2026-06-03 决策）：加密订阅 API 已完全绕过 IpAuth（后端插件坐实），
/// checkLogin 的「绑出口 IP」对订阅链路失去意义 → 移除，省一次请求 + 一个 IP 名额。
///
/// **触发点**（§ A，由 R4.6 接线层驱动）：T1 登录成功（force）/ T2 已登录冷启动 / T3 订单完成
/// （force）/ T4 主动刷新（force）/ T5 endpoint 切换 —— **文件化模型下 T5 等价再 sync 一次**
/// （file profile 无 url，无需重拼，直接从新竞速候选重拉重写文件），不再有独立 refreshUrl 路径。
///
/// **single-flight（B5）**：进行中复用同一 in-flight Future；force=true 在当前完成后补一次
/// （force 队列上限 1，多个合并）。**永不抛**（Property 1）。
library;

import 'dart:async';

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show TokenStorage;

import '../data/xboard_database.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';
import '../util/pii_mask.dart';
import 'encrypted_subscription_service.dart';
import 'profile_sync_port.dart';

/// R7 同步结果（供 UI/调用方判定，error 静默不抛）。
enum XbSyncOutcome { ok, noSubscription, authExpired, failed, skipped }

/// 订阅 endpoint 竞速候选 host 列表的提供者（解耦 [EndpointRaceController]，决策 #14 风格）。
/// 返回已排序去重的 host 串（首发在前 + 地区序替补，R4.2 `subscriptionCandidates()`）；
/// 空列表 → [EncryptedSubscriptionService] 退回原 URL host 兜底。
typedef SubscriptionCandidatesProvider = List<String> Function();

class XboardSubscriptionService {
  XboardSubscriptionService({
    required XboardService service,
    required EncryptedSubscriptionService encrypted,
    required ProfileSyncPort profilePort,
    required XboardDatabase db,
    required TokenStorage tokenStorage,
    SubscriptionCandidatesProvider? subscriptionCandidates,
    void Function(String winnerHost)? onWinnerHost,
    String flavorId = 'default',
  })  : _service = service,
        _encrypted = encrypted,
        _port = profilePort,
        _db = db,
        _tokenStorage = tokenStorage,
        _candidates = subscriptionCandidates ?? (() => const <String>[]),
        _onWinnerHost = onWinnerHost,
        _flavorId = flavorId;

  final XboardService _service;
  final EncryptedSubscriptionService _encrypted;
  final ProfileSyncPort _port;
  final XboardDatabase _db;
  final TokenStorage _tokenStorage;
  final SubscriptionCandidatesProvider _candidates;

  /// 成功拉取后回调命中的订阅 host（R4.6 接线层可据此更新竞速 current sub，下次从好地址起）。
  final void Function(String winnerHost)? _onWinnerHost;
  final String _flavorId;

  Completer<XbSyncOutcome>? _inFlight;
  bool _pendingForce = false;

  /// θ-8：退出登录期间为 true —— 新 sync 直接 skip（避免删 profile 后 in-flight sync 重建孤儿）。
  bool _loggingOut = false;

  /// R7 主同步（single-flight + force 队列，§ A）。
  Future<XbSyncOutcome> sync({bool force = false}) async {
    if (_loggingOut) return XbSyncOutcome.skipped; // 登出期间不同步（θ-8）。
    final inFlight = _inFlight;
    if (inFlight != null) {
      if (force) _pendingForce = true; // 队列上限 1，多个 force 合并。
      return inFlight.future;
    }
    final completer = Completer<XbSyncOutcome>();
    _inFlight = completer;
    var outcome = XbSyncOutcome.failed;
    try {
      outcome = await _doSync();
      if (_pendingForce) {
        _pendingForce = false;
        outcome = await _doSync();
      }
    } catch (_) {
      outcome = XbSyncOutcome.failed; // 永不抛。
    } finally {
      completer.complete(outcome);
      _inFlight = null;
    }
    return outcome;
  }

  Future<XbSyncOutcome> _doSync() async {
    // 1. 拿订阅 URL（含 token）。失败 → 用 getSubscription 区分无套餐 / 鉴权过期。
    final subUrlResult = await _service.getSubscribeUrl();
    if (subUrlResult case XbFailure()) {
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
    final originalUrl = (subUrlResult as XbSuccess<String>).data;

    // 2. 按竞速候选 host 串行 failOver 拉密文 + 解密（R4.1/R4.2）。
    final result = await _encrypted.fetchWithFailOver(
      originalUrl,
      candidateHosts: _candidates(),
    );
    if (!result.isSuccess) {
      return _mapFetchFailure(result.failure!);
    }

    // 3. 写 file 型 profile（明文 YAML 字节）+ 维护外挂索引（去重：同用户同 flavor 一个 profile）。
    final userIdHash = await _currentUserIdHash();
    final existingId =
        await _db.findProfileId(flavorId: _flavorId, userIdHash: userIdHash);
    final live = existingId != null && _port.currentProfileIds().contains(existingId);
    try {
      final newId = await _port.putFileProfile(
        profileId: live ? existingId : null,
        yamlBytes: result.yamlBytes!,
        label: '我的套餐',
      );
      if (!live) {
        await _db.putIndex(
            profileId: newId, flavorId: _flavorId, userIdHash: userIdHash);
      }
    } catch (_) {
      // saveFile/validateConfig 失败（中文字符串异常，R7.9）→ failed。
      return XbSyncOutcome.failed;
    }

    // 4. 回馈命中 host（接线层可更新竞速 current sub；纯通知，失败无害）。
    final host = _hostOf(result.winnerUrl);
    if (host != null) _onWinnerHost?.call(host);

    return XbSyncOutcome.ok;
  }

  /// R7.12 退出登录删 profile + 清索引（C7）。
  Future<void> clearForLogout(String userIdHash) async {
    final id =
        await _db.findProfileId(flavorId: _flavorId, userIdHash: userIdHash);
    if (id != null) {
      try {
        await _port.deleteProfile(id);
      } catch (_) {}
      await _db.deleteByProfileId(id);
    }
  }

  /// 退出登录便捷入口（数据一致性 § B step 4）：内部用**当前 token** 算 userIdHash 再删
  /// profile + 索引。**必须在反腐层 logout 清 token 之前调**（清 token 后 hash 变 null 找不到）。
  ///
  /// **θ-8 race 防御**：先置 `_loggingOut`（挡新 sync）→ await 在途 sync 完成（避免它在删除
  /// 后重建孤儿 profile）→ 再删。删完不复位 flag（本 service 实例随账号生命周期，下次登录
  /// 新容器/新实例；若同实例复用，bootstrap 重新注入时为新实例）。
  Future<void> clearForCurrentUser() async {
    _loggingOut = true;
    // await 在途 sync 完成（single-flight 的 Completer），避免删后重建。
    final inFlight = _inFlight;
    if (inFlight != null) {
      try {
        await inFlight.future;
      } catch (_) {}
    }
    final userIdHash = await _currentUserIdHash();
    await clearForLogout(userIdHash);
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

  /// 加密订阅拉取失败 → 同步结果（呼应错误透传：业务类各有语义，网络/解密类归 failed）。
  XbSyncOutcome _mapFetchFailure(EncryptedSubscriptionFailure f) => switch (f) {
        EncryptedSubscriptionFailure.unauthorized => XbSyncOutcome.authExpired,
        EncryptedSubscriptionFailure.noActivePlan => XbSyncOutcome.noSubscription,
        EncryptedSubscriptionFailure.noSubscribeUrl ||
        EncryptedSubscriptionFailure.serverNotConfigured ||
        EncryptedSubscriptionFailure.network ||
        EncryptedSubscriptionFailure.decryptFailed ||
        EncryptedSubscriptionFailure.unknown =>
          XbSyncOutcome.failed,
      };

  bool _isUnauthorized(Object error) =>
      error.runtimeType.toString().contains('XbUnauthorized');

  /// 从命中的加密订阅 URL 还原候选 host（`scheme://host[:port]`，对齐竞速候选形态）。
  String? _hostOf(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.hasPort
        ? '${uri.scheme}://${uri.host}:${uri.port}'
        : '${uri.scheme}://${uri.host}';
  }

  Future<String> _currentUserIdHash() async {
    final token = await _tokenStorage.readToken();
    return userIdHashFromToken(token);
  }
}
