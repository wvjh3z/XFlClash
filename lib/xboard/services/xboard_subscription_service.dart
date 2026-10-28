/// R7/R4.6 订阅自动同步（数据一致性总章 § A / B5 single-flight / v0.2 R4 文件化加密订阅）。
///
/// **v0.2 R4 重构**（取代 v0.1 的「复用 FlClash `Profile.update` 拉 URL」D62 方案）：SDK 自拉
/// 加密订阅密文 → 解密 → 明文 ClashMeta YAML 字节 → 写 **file 型 profile** 喂 FlClash core。
/// 链路：`getSubscribeUrl()`（拿带 token 的原订阅 URL）→ [EncryptedSubscriptionService.fetchWithFailOver]
/// （按地区分组限并发下载 + 解密）→ [ProfileSyncPort.putFileProfile]
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

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show TokenStorage;

import '../data/xboard_database.dart';
import '../models/bootstrap_payload.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';
import '../util/pii_mask.dart';
import 'encrypted_subscription_service.dart';
import 'profile_sync_port.dart';
import 'sentry_bootstrap.dart';

/// R7 同步结果（供 UI/调用方判定，error 静默不抛）。
///
/// 状态全部由加密订阅端点的服务端真相决定（插件错误码，token-in-URL 不依赖登录 JWT）：
/// 40304→[subscriptionExpired]、40305→[noSubscription]、40307→[trafficExhausted]、
/// 明确 40301/40302/40303→[authExpired]；裸 HTTP 拒绝不认定 API 会话失效。
enum XbSyncOutcome {
  ok,
  noSubscription,
  subscriptionExpired,
  trafficExhausted,
  authExpired,
  failed,
  skipped,
}

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
    List<BootstrapEndpoint> Function()? subscriptionEndpoints,
    bool Function()? vpnActive,
    List<Duration> retryDelays = const [
      Duration(seconds: 3),
      Duration(seconds: 10),
    ],
    void Function(String winnerHost)? onWinnerHost,
    void Function(String)? Function()? captureWinnerRecorder,
    int Function()? sessionRevision,
    String flavorId = 'default',
  }) : _service = service,
       _encrypted = encrypted,
       _port = profilePort,
       _db = db,
       _tokenStorage = tokenStorage,
       _candidates = subscriptionCandidates ?? (() => const <String>[]),
       _endpoints = subscriptionEndpoints,
       _vpnActive = vpnActive ?? (() => false),
       _retryDelays = List.unmodifiable(retryDelays),
       _onWinnerHost = onWinnerHost,
       _captureWinnerRecorder = captureWinnerRecorder,
       _sessionRevision = sessionRevision ?? (() => 0),
       _flavorId = flavorId;

  final XboardService _service;
  final EncryptedSubscriptionService _encrypted;
  final ProfileSyncPort _port;
  final XboardDatabase _db;
  final TokenStorage _tokenStorage;
  final SubscriptionCandidatesProvider _candidates;

  /// 成功拉取后回调命中的订阅 host（R4.6 接线层可据此更新竞速 current sub，下次从好地址起）。
  final void Function(String winnerHost)? _onWinnerHost;
  final void Function(String)? Function()? _captureWinnerRecorder;
  final String _flavorId;
  final int Function() _sessionRevision;

  final List<BootstrapEndpoint> Function()? _endpoints;
  final bool Function() _vpnActive;
  final List<Duration> _retryDelays;
  Timer? _retryTimer;
  String? _retryOwner;
  int? _retryRevision;
  int _retryGeneration = 0;
  int _retryAttempt = 0;
  bool _retryable = false;
  bool _disposed = false;
  CancelToken? _downloadCancel;
  String _stage = 'idle';

  void dispose() {
    _disposed = true;
    _retryGeneration++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _downloadCancel?.cancel('session ended');
  }

  /// Resume/address availability only accelerates an already scheduled retry.
  void recoverPending() {
    if (_retryTimer?.isActive != true || _inFlight != null) return;
    _retryTimer!.cancel();
    _retryTimer = null;
    unawaited(_runPendingRetry());
  }

  void _scheduleRetry(String ownerHash, int revision) {
    if (!_isCurrent(revision) ||
        !_retryable ||
        _retryAttempt >= _retryDelays.length) {
      return;
    }
    _retryGeneration++;
    _retryOwner = ownerHash;
    _retryRevision = revision;
    final delay = _retryDelays[_retryAttempt++];
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_runPendingRetry());
    });
  }

  Future<void> _runPendingRetry() async {
    final generation = _retryGeneration;
    final owner = _retryOwner;
    final revision = _retryRevision;
    _retryOwner = null;
    _retryRevision = null;
    try {
      if (owner != null &&
          revision != null &&
          await _ownsSession(owner, revision) &&
          generation == _retryGeneration &&
          _isCurrent(revision)) {
        await _sync(isRetry: true);
      }
    } catch (_) {
      debugPrint('[Subscription] retry session_check_failed');
    }
  }

  Completer<XbSyncOutcome>? _inFlight;
  bool _pendingForce = false;
  bool _reconciling = false;

  /// 是否正在同步（in-flight）。供 UI 区分「加载中」与「无套餐」（首页连接拦截 1-B：
  /// 已登录但 profile 还没生成时，若正在 sync → 提示「正在准备线路」而非「无可用线路」）。
  bool get isSyncing => _inFlight != null;

  /// θ-8：退出登录期间为 true —— 新 sync 直接 skip（避免删 profile 后 in-flight sync 重建孤儿）。
  bool _loggingOut = false;
  Future<void>? _cleanupFuture;
  String? _cleanupOwnerHash;

  /// R7 主同步（single-flight + force 队列，§ A）。
  Future<XbSyncOutcome> sync({bool force = false}) => _sync(force: force);

  Future<XbSyncOutcome> _sync({
    bool force = false,
    bool isRetry = false,
  }) async {
    if (_disposed || _loggingOut || _reconciling) {
      return XbSyncOutcome.skipped; // 登出期间不同步（θ-8）。
    }
    final inFlight = _inFlight;
    if (inFlight != null) {
      if (force) _pendingForce = true; // 队列上限 1，多个 force 合并。
      return inFlight.future;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!isRetry) {
      _retryGeneration++;
      _retryAttempt = 0;
    }
    final revision = _sessionRevision();
    String? ownerHash;
    final watch = Stopwatch()..start();
    final completer = Completer<XbSyncOutcome>();
    _inFlight = completer;
    var outcome = XbSyncOutcome.failed;
    try {
      final token = await _tokenStorage.readToken();
      if (token == null || token.isEmpty || !_isCurrent(revision)) {
        outcome = XbSyncOutcome.skipped;
        return outcome;
      }
      // 在网络请求前捕获归属，不能在 A 下载完成后才读取已属于 B 的 Token。
      ownerHash = userIdHashFromToken(token);
      outcome = await _doSync(ownerHash, revision);
      if (_pendingForce && await _ownsSession(ownerHash, revision)) {
        _pendingForce = false;
        outcome = await _doSync(ownerHash, revision);
      }
    } catch (e, s) {
      outcome = XbSyncOutcome.failed; // 永不抛。
      // #2 监测：网络/业务失败已在 _doSync 内归一为 outcome（不抛），故能到这里 = 未预期异常
      // （蓝图外的 throw）→ 上报 Sentry。dsn 空 → no-op；Sentry 按 fingerprint 去重不刷屏。
      SentryBootstrap.captureException(
        e,
        stackTrace: s,
        where: 'subscription sync (unexpected)',
      );
    } finally {
      completer.complete(outcome);
      _inFlight = null;
      _pendingForce = false;
      debugPrint(
        '[Subscription] sync stage=$_stage result=${outcome.name} '
        'ms=${watch.elapsedMilliseconds} retry=$_retryAttempt',
      );
      if (outcome == XbSyncOutcome.failed && ownerHash != null) {
        _scheduleRetry(ownerHash, revision);
      }
    }
    return outcome;
  }

  Future<XbSyncOutcome> _doSync(String ownerHash, int revision) async {
    _retryable = false;
    _stage = 'get_url';
    if (!await _ownsSession(ownerHash, revision)) return XbSyncOutcome.skipped;
    // 1. 拿订阅 URL（含 token）。失败 → 用 getSubscription 区分无套餐 / 鉴权过期。
    final subUrlResult = await _service.getSubscribeUrl();
    if (!await _ownsSession(ownerHash, revision)) return XbSyncOutcome.skipped;
    if (subUrlResult case XbFailure(:final error)) {
      _retryable = error is XbNetwork;
      final sub = await _service.getSubscription();
      if (!await _ownsSession(ownerHash, revision)) {
        return XbSyncOutcome.skipped;
      }
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

    // 2. 按地区分组限并发下载 + 解密。
    _stage = 'download_decrypt';
    final vpnActive = _vpnActive();
    final recordWinner = _captureWinnerRecorder != null
        ? _captureWinnerRecorder()
        : _onWinnerHost;
    _downloadCancel = CancelToken();
    final result = await _encrypted.fetchWithFailOver(
      originalUrl,
      candidateHosts: _candidates(),
      endpoints: _endpoints?.call(),
      vpnActive: vpnActive,
      cancelToken: _downloadCancel,
    );
    if (!await _ownsSession(ownerHash, revision)) return XbSyncOutcome.skipped;
    if (!result.isSuccess) {
      _retryable = result.failure == EncryptedSubscriptionFailure.network;
      return _mapFetchFailure(result.failure!);
    }

    // 3. 写 file 型 profile（明文 YAML 字节）+ 维护外挂索引（去重：同用户同 flavor 一个 profile）。
    final writeOutcome = await _db.profileMutations.run(
      _flavorId,
      ownerHash,
      () async {
        if (!await _ownsSession(ownerHash, revision)) {
          return XbSyncOutcome.skipped;
        }
        _stage = 'lookup_profile';
        int? reservedId;
        try {
          final ids = await _db.findProfileIds(
            flavorId: _flavorId,
            userIdHash: ownerHash,
          );
          if (!await _ownsSession(ownerHash, revision)) {
            return XbSyncOutcome.skipped;
          }
          final liveIds = _port.currentProfileIds().toSet();
          final existingId =
              ids.where(liveIds.contains).firstOrNull ?? ids.firstOrNull;
          // Keep one recoverable identity, including when its main row is missing.
          // Never drop cleanup evidence until both the old file and main row are gone.
          for (final id in ids.where((id) => id != existingId)) {
            if (!await _ownsSession(ownerHash, revision)) {
              return XbSyncOutcome.skipped;
            }
            await _port.deleteProfile(id);
            await _db.deleteByProfileId(id);
          }
          if (!await _ownsSession(ownerHash, revision)) {
            return XbSyncOutcome.skipped;
          }
          _stage = 'write_apply_profile';
          final newId = await _port.putFileProfile(
            profileId: existingId,
            yamlBytes: result.yamlBytes!,
            label: '我的套餐',
            isSessionCurrent: () => _isCurrent(revision),
            beforeWrite: (id) async {
              if (!await _ownsSession(ownerHash, revision)) {
                throw const ProfileSyncCancelled();
              }
              _stage = 'reserve_index';
              await _db.putIndex(
                profileId: id,
                flavorId: _flavorId,
                userIdHash: ownerHash,
              );
              reservedId = id;
              if (!await _ownsSession(ownerHash, revision)) {
                throw const ProfileSyncCancelled();
              }
              _stage = 'write_apply_profile';
            },
          );
          if (!await _ownsSession(ownerHash, revision)) {
            await _discardProfile(newId);
            return XbSyncOutcome.skipped;
          }
        } on ProfileSyncCancelled {
          if (reservedId != null) await _discardProfile(reservedId!);
          return XbSyncOutcome.skipped;
        } catch (e, s) {
          if (reservedId != null && !await _ownsSession(ownerHash, revision)) {
            await _discardProfile(reservedId!);
            return XbSyncOutcome.skipped;
          }
          // saveFile/validateConfig 失败（中文字符串异常，R7.9）→ failed。
          // #2 监测：写/校验 ClashMeta 配置失败是核心功能盲区（节点不更新），上报 Sentry。
          SentryBootstrap.captureException(
            e,
            stackTrace: s,
            where: 'subscription putProfile (saveFile/validateConfig)',
          );
          return XbSyncOutcome.failed;
        }

        return XbSyncOutcome.ok;
      },
    );
    if (writeOutcome != XbSyncOutcome.ok) return writeOutcome;

    // 4. 回馈命中 host（接线层可更新竞速 current sub；纯通知，失败无害）。
    final host = _hostOf(result.winnerUrl);
    if (host != null && vpnActive == _vpnActive()) recordWinner?.call(host);
    _stage = 'complete';

    return XbSyncOutcome.ok;
  }

  /// R7.12 退出登录删 profile + 清索引（C7）。
  Future<void> clearForLogout(String userIdHash) async {
    await clearForSessionOwner(userIdHash);
  }

  /// SDK 已清 Token 时仍以认证编排保留的旧归属清理，不读取当前（可能为 B）的 Token。
  /// 在任何 await 前封住服务；不等待慢下载/内核校验，晚到响应由会话 guard 丢弃。
  /// 清理失败保留该条索引并继续其他记录，最后报告失败，便于后续恢复。
  Future<void> clearForSessionOwner(String ownerHash) {
    _loggingOut = true;
    dispose();
    _pendingForce = false;
    if (ownerHash.isEmpty || ownerHash == 'anon') return Future<void>.value();
    // 同一个已经结束的服务只清理一次。重复认证失败/登出通知不能在新会话开始后
    // 再次按 owner 扫描，误删新会话刚创建的 Profile。
    if (_cleanupOwnerHash != null && _cleanupOwnerHash != ownerHash) {
      return Future<void>.error(StateError('Session cleanup owner changed'));
    }
    _cleanupOwnerHash = ownerHash;
    return _cleanupFuture ??= _clearSessionOwner(ownerHash);
  }

  Future<void> _clearSessionOwner(String ownerHash) async {
    final deferred = _db.profileMutations.isBusy(_flavorId, ownerHash);
    final stop = deferred
        ? _deactivateSessionOwner(ownerHash)
        : Future<void>.value();
    final cleanup = _db.profileMutations.run(_flavorId, ownerHash, () async {
      await stop;
      await _clearSessionOwnerNow(ownerHash);
    });
    if (!deferred) return cleanup;
    // Do not hold logout UI behind an uninterruptible file/core operation.
    // The queued cleanup precedes subsequent same-owner writes, even after the
    // provider is disposed. Its errors are observed and ownership is retained.
    unawaited(
      cleanup.catchError((Object error, StackTrace stack) {
        SentryBootstrap.captureException(
          error,
          stackTrace: stack,
          where: 'subscription deferred session cleanup',
        );
      }),
    );
    // Preserve logout's immediate stop of the selected owned VPN Profile.
    // Only destructive disk cleanup waits for the persistence lane.
    await stop;
  }

  Future<void> _deactivateSessionOwner(String ownerHash) async {
    final ids = await _db.findProfileIds(
      flavorId: _flavorId,
      userIdHash: ownerHash,
    );
    for (final id in ids) {
      await _port.deactivateProfile(id);
    }
  }

  Future<void> _clearSessionOwnerNow(String ownerHash) async {
    final ids = await _db.findProfileIds(
      flavorId: _flavorId,
      userIdHash: ownerHash,
    );
    final failures = <int>[];
    for (final id in ids) {
      try {
        await _port.deleteProfile(id);
        await _db.deleteByProfileId(id);
      } catch (e, s) {
        failures.add(id);
        SentryBootstrap.captureException(
          e,
          stackTrace: s,
          where: 'subscription session cleanup',
        );
      }
    }
    if (failures.isNotEmpty) {
      throw StateError('Session Profile cleanup failed for IDs: $failures');
    }
  }

  /// 显式登出的兼容入口，必须仍持有旧 Token。认证失效时使用 clearForSessionOwner，
  /// 因 SDK 此时可能已经删除 Token。立即封住旧服务，不等待在途下载/校验。
  Future<void> clearForCurrentUser() async {
    _loggingOut = true;
    dispose();
    final userIdHash = await _currentUserIdHash();
    await clearForSessionOwner(userIdHash);
  }

  /// Explicit orphan cleanup must retain ownership until file deletion succeeds.
  /// Never race the in-flight reservation/write or scan another account's data.
  Future<void> validateProfileIndex() async {
    if (_inFlight != null || _disposed || _loggingOut || _reconciling) return;
    _reconciling = true;
    try {
      final revision = _sessionRevision();
      final owner = await _currentUserIdHash();
      if (!await _ownsSession(owner, revision)) return;
      await _db.profileMutations.run(_flavorId, owner, () async {
        if (!await _ownsSession(owner, revision)) return;
        final ids = await _db.findProfileIds(
          flavorId: _flavorId,
          userIdHash: owner,
        );
        for (final id in ids) {
          if (!await _ownsSession(owner, revision)) return;
          if (!_port.currentProfileIds().contains(id)) {
            await _port.deleteProfile(id);
            await _db.deleteByProfileId(id);
          }
        }
      });
    } finally {
      _reconciling = false;
    }
  }

  // ───────── helpers ─────────

  /// 加密订阅拉取失败 → 同步结果（呼应错误透传：业务类各有语义，网络/解密类归 failed）。
  XbSyncOutcome _mapFetchFailure(EncryptedSubscriptionFailure f) => switch (f) {
    EncryptedSubscriptionFailure.unauthorized => XbSyncOutcome.authExpired,
    EncryptedSubscriptionFailure.subscriptionExpired =>
      XbSyncOutcome.subscriptionExpired,
    EncryptedSubscriptionFailure.trafficExhausted =>
      XbSyncOutcome.trafficExhausted,
    EncryptedSubscriptionFailure.noActivePlan => XbSyncOutcome.noSubscription,
    EncryptedSubscriptionFailure.noSubscribeUrl ||
    EncryptedSubscriptionFailure.serverNotConfigured ||
    EncryptedSubscriptionFailure.network ||
    EncryptedSubscriptionFailure.decryptFailed ||
    EncryptedSubscriptionFailure.unknown => XbSyncOutcome.failed,
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

  bool _isCurrent(int revision) =>
      !_disposed && !_loggingOut && _sessionRevision() == revision;

  Future<bool> _ownsSession(String ownerHash, int revision) async {
    if (!_isCurrent(revision)) return false;
    final token = await _tokenStorage.readToken();
    return _isCurrent(revision) &&
        token != null &&
        token.isNotEmpty &&
        userIdHashFromToken(token) == ownerHash;
  }

  Future<void> _discardProfile(int profileId) async {
    await _port.deleteProfile(profileId);
    await _db.deleteByProfileId(profileId);
  }
}
