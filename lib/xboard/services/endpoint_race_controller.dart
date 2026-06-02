/// API / 订阅 endpoint 竞速 + 被动健康检查 + 地区感知（R15.C / B4 / 决策 #10 / D10 / v0.2 R4.9）。
///
/// **What**：维护「当前 api/subscription endpoint」内存状态（不持久化 R15.C.16），失败立即切换 /
/// 网络变化重选 / 30 分钟切换 ≥5 次重新完整竞速 / onResume 异步竞速。
///
/// **竞速**：并发 GET `/guest/comm/config`，第一个 2xx 胜出（R15.C.15/19）。
/// **failOver 串行化锁（B4）**：单 Completer 队列，避免多并发失败抖动到不同 endpoint。
/// **决策 #10**：切换瞬间在途请求仅重试本次失败请求（SDK 无 CancelToken）。
/// **D10 null 兜底**：竞速前 current 为 null → 调用方回退 endpoints.first。
///
/// **🔵 v0.2 R4.9 地区感知**：endpoint 带 `region`（overseas/cn/unknown）。竞速按 VPN 开关状态
/// 分档（[vpnActive]）：
/// - **VPN 未开**：全部 endpoint 平等竞速（纯比速度）。
/// - **VPN 已开**：先在「海外档」竞速；海外全不可达 → 退「国内+未知档」兜底（保命不卡死）。
/// VPN 开关切换 → 调 [setVpnActive] 触发重竞速（用新档位重选）。
///
/// 永不抛（Property 1）：竞速 / 切换失败保持当前值。注入 dio 工厂便于测试。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../config/bootstrap_constants.dart';
import '../models/bootstrap_payload.dart';
import 'sentry_bootstrap.dart';

/// 竞速探针：给定 endpoint url 返回是否 2xx 可达（默认 GET /guest/comm/config）。
typedef EndpointProbe = Future<bool> Function(String endpoint);

/// endpoint 切换回调（hook 到 XBoardSDK.switchBaseUrl + apiEndpointProvider）。
typedef OnEndpointSwitch = void Function(String endpoint);

class EndpointRaceController {
  EndpointRaceController({
    EndpointProbe? probe,
    this.onApiSwitch,
    this.onSubscriptionSwitch,
    Dio? dio,
    bool vpnActive = false,
  })  : _probe = probe ?? _defaultProbe(dio ?? Dio()),
        _vpnActive = vpnActive,
        _now = DateTime.now;

  final EndpointProbe _probe;
  final OnEndpointSwitch? onApiSwitch;
  final OnEndpointSwitch? onSubscriptionSwitch;

  /// 可注入的时钟（测试用），默认 wall clock。
  DateTime Function() _now;

  /// VPN 当前是否开启（R4.9；由 xboard_module listen isStartProvider 注入）。
  bool _vpnActive;

  String? _currentApi;
  String? _currentSub;

  /// 完整 endpoint 列表（含 region，failOver / 重竞速复用）。
  List<BootstrapEndpoint> _apiEndpoints = const [];
  List<BootstrapEndpoint> _subEndpoints = const [];

  /// 30 分钟滚动窗口内的切换时间戳（R15.C.19）。
  final List<DateTime> _switchTimes = [];

  /// 累计完整竞速次数（DD-23 `endpoint.race_attempts` tag，W5.7）。
  int _raceAttempts = 0;

  /// failOver 串行化锁（B4）：进行中的 failOver 未完成时复用同一 Future。
  Future<void>? _inFlightFailOver;

  /// 当前 api endpoint（D10：null = 未竞速胜出，调用方回退 endpoints.first）。
  String? get currentApiEndpoint => _currentApi;

  /// 当前 subscription endpoint（D10 同上）。
  String? get currentSubscriptionEndpoint => _currentSub;

  /// 当前 VPN 状态（测试 / 调试可读）。
  bool get vpnActive => _vpnActive;

  /// 测试注入时钟。
  // ignore: use_setters_to_change_properties
  void debugSetClock(DateTime Function() clock) => _now = clock;

  static EndpointProbe _defaultProbe(Dio dio) => (endpoint) async {
        try {
          final resp = await dio
              .getUri<Object?>(Uri.parse('$endpoint/api/v1/guest/comm/config'))
              .timeout(kBootstrapPerMirrorTimeout);
          final code = resp.statusCode ?? 0;
          return code >= 200 && code < 300;
        } catch (_) {
          return false;
        }
      };

  /// VPN 开关状态变化（R4.9）：更新状态 + 用新档位重新竞速 api/sub（不阻塞调用方）。
  void setVpnActive(bool active) {
    if (active == _vpnActive) return;
    _vpnActive = active;
    if (_apiEndpoints.isNotEmpty) unawaited(raceApi(_apiEndpoints));
    if (_subEndpoints.isNotEmpty) unawaited(raceSubscription(_subEndpoints));
  }

  /// API endpoint 完整竞速（R15.C.15/19 + R4.9 地区感知）：按 VPN 状态分档竞速。
  Future<void> raceApi(List<BootstrapEndpoint> apiEndpoints) async {
    if (apiEndpoints.isEmpty) return;
    _apiEndpoints = List.unmodifiable(apiEndpoints);
    // DD-23：累计竞速次数 tag（W5.7 / 5.7.2 endpoint.race_attempts）。
    _raceAttempts++;
    SentryBootstrap.tagEndpoint(raceAttempts: _raceAttempts);
    final winner = await _raceRegionAware(apiEndpoints);
    if (winner != null && winner != _currentApi) {
      _currentApi = winner;
      onApiSwitch?.call(winner);
    } else if (_currentApi == null && winner != null) {
      _currentApi = winner;
      onApiSwitch?.call(winner);
    }
  }

  /// Subscription endpoint 竞速（R15.C.23 + R4.9 地区感知）。
  Future<void> raceSubscription(List<BootstrapEndpoint> subEndpoints) async {
    if (subEndpoints.isEmpty) return;
    _subEndpoints = List.unmodifiable(subEndpoints);
    final winner = await _raceRegionAware(subEndpoints);
    if (winner != null) {
      _currentSub = winner;
      onSubscriptionSwitch?.call(winner);
    }
  }

  /// 当前 API endpoint 失败 → 切下一个可达者（B4 串行化锁）。
  Future<void> failOverApi() async {
    // B4：进行中的 failOver 未完成 → 复用同一 Future（避免并发抖动）。
    final inFlight = _inFlightFailOver;
    if (inFlight != null) return inFlight;
    final future = _doFailOverApi();
    _inFlightFailOver = future;
    try {
      await future;
    } finally {
      _inFlightFailOver = null;
    }
  }

  Future<void> _doFailOverApi() async {
    if (_apiEndpoints.isEmpty) return;
    // 按 R4.9 档位顺序找第一个可达者（排除当前）；找不到则完整重竞速。
    final ordered = _orderByRegion(_apiEndpoints)
        .where((u) => u != _currentApi)
        .toList();
    for (final u in ordered) {
      if (await _probe(u)) {
        _switchApiTo(u);
        return;
      }
    }
    // 全不可达 → 完整重竞速兜底。
    await raceApi(_apiEndpoints);
  }

  void _switchApiTo(String endpoint) {
    _currentApi = endpoint;
    onApiSwitch?.call(endpoint);
    _recordSwitch();
  }

  /// 记录切换 + 30min 窗口内 ≥5 次则重新完整竞速（R15.C.19）。
  void _recordSwitch() {
    final now = _now();
    _switchTimes.add(now);
    _switchTimes.removeWhere((t) => now.difference(t) > kEndpointRaceWindow);
    if (_switchTimes.length >= kEndpointReraceThreshold) {
      _switchTimes.clear();
      // 异步重竞速（不阻塞当前切换）。
      unawaited(raceApi(_apiEndpoints));
    }
  }

  /// onResume / 网络变化触发后台竞速（R15.C.20/21，不阻塞 UI）。
  void refreshRaceInBackground() {
    if (_apiEndpoints.isNotEmpty) unawaited(raceApi(_apiEndpoints));
    if (_subEndpoints.isNotEmpty) unawaited(raceSubscription(_subEndpoints));
  }

  /// R4.9 地区感知竞速：
  /// - VPN 未开 → 全部 endpoint 平等并发竞速（纯比速度）。
  /// - VPN 已开 → 先竞「海外档」；海外全挂 → 退「国内+未知档」兜底。
  Future<String?> _raceRegionAware(List<BootstrapEndpoint> endpoints) async {
    final urls = endpoints
        .map((e) => e.url)
        .where((u) => u.isNotEmpty)
        .toList();
    if (urls.isEmpty) return null;

    if (!_vpnActive) {
      // 平等竞速。
      return _race(urls);
    }

    // VPN 开：海外优先。
    final overseas = endpoints
        .where((e) => e.region == BootstrapRegion.overseas && e.url.isNotEmpty)
        .map((e) => e.url)
        .toList();
    final rest = endpoints
        .where((e) => e.region != BootstrapRegion.overseas && e.url.isNotEmpty)
        .map((e) => e.url)
        .toList();

    if (overseas.isNotEmpty) {
      final w = await _race(overseas);
      if (w != null) return w; // 海外有可达 → 用海外。
    }
    // 海外全挂（或无海外档）→ 退国内+未知兜底。
    if (rest.isNotEmpty) return _race(rest);
    // 兜底再兜底：全集竞速（理论上 overseas 已覆盖，防御性）。
    return _race(urls);
  }

  /// 按 R4.9 档位排序（VPN 开：海外在前；VPN 关：保持原序）—— failOver 顺序用。
  List<String> _orderByRegion(List<BootstrapEndpoint> endpoints) {
    final valid = endpoints.where((e) => e.url.isNotEmpty).toList();
    if (!_vpnActive) return valid.map((e) => e.url).toList();
    final overseas = valid
        .where((e) => e.region == BootstrapRegion.overseas)
        .map((e) => e.url);
    final rest = valid
        .where((e) => e.region != BootstrapRegion.overseas)
        .map((e) => e.url);
    return [...overseas, ...rest];
  }

  /// 并发探测，返回第一个 2xx 胜出者（无可达返 null）。
  Future<String?> _race(List<String> endpoints) async {
    if (endpoints.isEmpty) return null;
    final completer = Completer<String?>();
    var pending = endpoints.length;
    for (final e in endpoints) {
      _probe(e).then((ok) {
        if (ok && !completer.isCompleted) {
          completer.complete(e);
        } else {
          pending--;
          if (pending == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }).catchError((_) {
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete(null);
      });
    }
    return completer.future;
  }

  void dispose() {
    _switchTimes.clear();
  }
}
