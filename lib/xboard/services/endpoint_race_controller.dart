/// API / 订阅 endpoint 竞速 + 被动健康检查（R15.C / B4 / 决策 #10 / D10）。
///
/// **What**：维护「当前 api/subscription endpoint」内存状态（不持久化 R15.C.16），失败立即切换 /
/// 网络变化重选 / 30 分钟切换 ≥5 次重新完整竞速 / onResume 异步竞速。
///
/// **竞速**：并发 GET `/guest/comm/config`，第一个 2xx 胜出（R15.C.15/19）。
/// **failOver 串行化锁（B4）**：单 Completer 队列，避免多并发失败抖动到不同 endpoint。
/// **决策 #10**：切换瞬间在途请求仅重试本次失败请求（SDK 无 CancelToken）。
/// **D10 null 兜底**：竞速前 current 为 null → 调用方回退 endpoints.first。
///
/// 永不抛（Property 1）：竞速 / 切换失败保持当前值。注入 dio 工厂便于测试。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../config/bootstrap_constants.dart';

/// 竞速探针：给定 endpoint 返回是否 2xx 可达（默认 GET /guest/comm/config）。
typedef EndpointProbe = Future<bool> Function(String endpoint);

/// endpoint 切换回调（hook 到 XBoardSDK.switchBaseUrl + apiEndpointProvider）。
typedef OnEndpointSwitch = void Function(String endpoint);

class EndpointRaceController {
  EndpointRaceController({
    EndpointProbe? probe,
    this.onApiSwitch,
    this.onSubscriptionSwitch,
    Dio? dio,
  })  : _probe = probe ?? _defaultProbe(dio ?? Dio()),
        _now = DateTime.now;

  final EndpointProbe _probe;
  final OnEndpointSwitch? onApiSwitch;
  final OnEndpointSwitch? onSubscriptionSwitch;

  /// 可注入的时钟（测试用），默认 wall clock。
  DateTime Function() _now;

  String? _currentApi;
  String? _currentSub;
  List<String> _apiEndpoints = const [];

  /// 30 分钟滚动窗口内的切换时间戳（R15.C.19）。
  final List<DateTime> _switchTimes = [];

  /// failOver 串行化锁（B4）：进行中的 failOver 未完成时复用同一 Future。
  Future<void>? _inFlightFailOver;

  /// 当前 api endpoint（D10：null = 未竞速胜出，调用方回退 endpoints.first）。
  String? get currentApiEndpoint => _currentApi;

  /// 当前 subscription endpoint（D10 同上）。
  String? get currentSubscriptionEndpoint => _currentSub;

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

  /// API endpoint 完整竞速（R15.C.15/19）：并发探测，第一个 2xx 胜出。
  Future<void> raceApi(List<String> apiEndpoints) async {
    if (apiEndpoints.isEmpty) return;
    _apiEndpoints = List.unmodifiable(apiEndpoints);
    final winner = await _race(apiEndpoints);
    if (winner != null && winner != _currentApi) {
      _currentApi = winner;
      onApiSwitch?.call(winner);
    } else if (_currentApi == null && winner != null) {
      _currentApi = winner;
      onApiSwitch?.call(winner);
    }
  }

  /// Subscription endpoint 竞速（R15.C.23，触发时机限登录首次/主动刷新/订单完成）。
  Future<void> raceSubscription(List<String> subEndpoints) async {
    if (subEndpoints.isEmpty) return;
    final winner = await _race(subEndpoints);
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
    // 从当前之后的候选里找第一个可达者；找不到则完整重竞速。
    final ordered = [
      ..._apiEndpoints.where((e) => e != _currentApi),
    ];
    for (final e in ordered) {
      if (await _probe(e)) {
        _switchApiTo(e);
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
  }

  /// 并发探测，返回第一个 2xx 胜出者（无可达返 null）。
  Future<String?> _race(List<String> endpoints) async {
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
