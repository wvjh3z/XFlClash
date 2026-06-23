/// Geo 数据库（GEOIP / GEOSITE / MMDB / ASN）按需自动更新（xboard 自有，无接缝点）。
///
/// **需求**：仅在「连上 VPN 的那一刻」且「距上次成功更新 ≥ 7 天」时才更新——
/// 没连 VPN 不更新（默认 geox-url 多为 GitHub，未连接在国内拉不动）；连上但没满 7 天也不更新。
///
/// **机制**：不依赖内核的 `geo-auto-update`（那个按「连续运行小时数」计、跨重启归零、移动端基本
/// 不触发，且无法按「是否已连接」开关）。改由本服务在 `isStartProvider` false→true 跃迁时（见
/// `xboard_module` 接线）调用，自己用**持久化时间戳**判 7 天、调 FlClash 既有 `updateGeoData`。
///
/// **零接缝点**：全是 xboard 层新增代码 + 调用 FlClash 既有 API（`coreController.updateGeoData`），
/// 不改任何上游文件。
library;

import 'dart:async';

import 'package:fl_clash/common/constant.dart' show GEOIP, GEOSITE, MMDB, ASN;
import 'package:fl_clash/core/core.dart' show coreController;
import 'package:fl_clash/models/models.dart' show UpdateGeoDataParams;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单个 geo 库的「类型标签 + 文件名」（与设置→资源页一致）。
class _GeoTarget {
  const _GeoTarget(this.label, this.fileName);
  final String label; // geoType（'GEOIP'/'GEOSITE'/'MMDB'/'ASN'）
  final String fileName; // geoName（GEOIP.dat 等）
}

abstract final class XbGeoUpdateService {
  /// 更新间隔：距上次**成功**更新满此时长才再更新（需求：大于 7 天）。
  static const Duration interval = Duration(days: 7);

  /// 失败后的会话内尝试节流：避免「连/断/重连」反复触发拉取（仅内存，重启归零）。
  static const Duration _attemptThrottle = Duration(minutes: 30);

  /// 连上 VPN 后延迟多久再拉：给隧道 / DNS 一点稳定时间，避免刚连上网络未就绪就拉 GitHub 失败。
  static const Duration _settleDelay = Duration(seconds: 45);

  /// 持久化「上次成功更新时刻」的 prefs 键（毫秒时间戳）。
  static const String _kPrefsKey = 'xb_geo_last_update_at_ms';

  static const List<_GeoTarget> _targets = [
    _GeoTarget('GEOIP', GEOIP),
    _GeoTarget('GEOSITE', GEOSITE),
    _GeoTarget('MMDB', MMDB),
    _GeoTarget('ASN', ASN),
  ];

  /// 进行中标记（single-flight，防并发重复拉取）。
  static bool _running = false;

  /// 本会话上次尝试时刻（内存，配合 [_attemptThrottle] 防失败后频繁重试）。
  static DateTime? _lastAttemptAt;

  /// 连上后的延迟定时器（[onConnected] 起、[onDisconnected] / 触发后清）。
  static Timer? _pendingTimer;

  /// 刚连上 VPN：延迟 [_settleDelay] 后、若仍连着，再检查是否需要更新 geo 库。
  ///
  /// 调用点：`xboard_module` 的 `isStartProvider` false→true 跃迁。延迟期间断开 → [onDisconnected]
  /// 取消；到点时用 [stillConnected] 复核仍连着才真拉（避免刚连上网络未就绪 / 已断开还硬拉）。
  static void onConnected(bool Function() stillConnected) {
    _pendingTimer?.cancel();
    _pendingTimer = Timer(_settleDelay, () {
      _pendingTimer = null;
      if (!stillConnected()) return; // 延迟到点已断开 → 不更新。
      // ignore: discarded_futures
      checkAndUpdate();
    });
  }

  /// 断开 VPN：取消尚未到点的延迟检查（连上→很快断开时不应再拉）。
  static void onDisconnected() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
  }

  /// 满足「≥7 天未更新」则后台更新 4 个 geo 库。fire-and-forget、永不抛。
  ///
  /// 一般由 [onConnected] 延迟后调用；也可手动直接调（如设置里「立即检查」）。
  static Future<void> checkAndUpdate() async {
    if (_running) return;

    final now = DateTime.now();

    // 会话内失败重试节流：上次尝试不足 30 分钟 → 跳过（防连断重连刷请求）。
    final lastAttempt = _lastAttemptAt;
    if (lastAttempt != null && now.difference(lastAttempt) < _attemptThrottle) {
      return;
    }

    // 7 天判定（持久化时间戳，跨重启有效）。
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return; // prefs 不可用 → 静默跳过。
    }
    final lastMs = prefs.getInt(_kPrefsKey);
    if (lastMs != null) {
      final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (now.difference(last) < interval) return; // 未满 7 天 → 不更新。
    }

    _running = true;
    _lastAttemptAt = now;
    try {
      var allOk = true;
      for (final t in _targets) {
        try {
          // updateGeoData 成功返空串，失败返错误消息（与设置→资源页同源）。
          final msg = await coreController.updateGeoData(
            UpdateGeoDataParams(geoType: t.label, geoName: t.fileName),
          );
          if (msg.isNotEmpty) {
            allOk = false;
            debugPrint('[XbGeoUpdate] ${t.label} 更新失败: $msg');
          }
        } catch (e) {
          allOk = false;
          debugPrint('[XbGeoUpdate] ${t.label} 更新异常: $e');
        }
      }
      // 仅全部成功才写时间戳；有失败则不写 → 下次连上（过节流后）重试，不必等 7 天。
      if (allOk) {
        await prefs.setInt(_kPrefsKey, DateTime.now().millisecondsSinceEpoch);
        debugPrint('[XbGeoUpdate] 4 个 geo 库已更新');
      }
    } finally {
      _running = false;
    }
  }
}
