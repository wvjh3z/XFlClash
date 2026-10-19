/// 客户端版本更新检查服务（形态 A「设置」页 + 冷启动自动检查）。
///
/// **职责**:
/// - 冷启动(bootstrap 完成后)自动检查一次 → 有更新 → 写 provider
/// - 设置页「检查更新」按钮 → 手动检查 → 弹更新弹窗 / toast 无更新
/// - 对比 versionCode → 服务端 > 本地 → 有更新
/// - 强制更新(force)→ 弹窗不可关（仅「立即更新」按钮）
/// - 按 region + 用户当前网络选优先源下载(档1: 外部浏览器打开)
///
/// **依赖**: SDK `appUpdate` API + package_info_plus
library;

import 'dart:async';
import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show AppUpdateModel, XBoardSDK;

import '../providers/xboard_providers.dart';
import 'endpoint_race_controller.dart';

/// 更新检查结果。
sealed class UpdateCheckResult {}

/// 有更新可用。
class UpdateAvailable extends UpdateCheckResult {
  final AppUpdateModel info;
  final int currentVersionCode;
  UpdateAvailable(this.info, this.currentVersionCode);
}

/// 已是最新版。
class UpdateNotAvailable extends UpdateCheckResult {}

/// 检查失败（网络/服务端错误），静默不打扰用户。
class UpdateCheckFailed extends UpdateCheckResult {
  final Object error;
  UpdateCheckFailed(this.error);
}

class _UpdateFlight {
  late final Future<UpdateCheckResult> result;
  String? requestedBase;
}

class _StartupSuccess {
  _StartupSuccess(this.result, this.base);
  final UpdateCheckResult result;
  final String base;
}

class _AutomaticUpdateState {
  int running = 0;
  bool pendingRecovery = false;
  bool throttledRecovery = false;
  String? failedBase;
  _StartupSuccess? startupSuccess;
}

class XbUpdateService {
  XbUpdateService._();

  static var _inFlight = Expando<_UpdateFlight>();
  static var _automatic = Expando<_AutomaticUpdateState>();

  /// 执行一次更新检查。
  ///
  /// [sdk] — 已 initialize 的 SDK 实例。
  /// [endpoints] waits for a probed API; retry only after an actual valid switch.
  /// 返回 sealed [UpdateCheckResult]。调用方决定如何展示（弹窗/toast/静默）。
  static Future<UpdateCheckResult> check(
    XBoardSDK sdk, {
    required EndpointRaceController? endpoints,
  }) {
    if (endpoints == null) {
      return Future.value(UpdateCheckFailed(StateError('API is not ready')));
    }
    // Manual and pre-download checks only join a request that is still running.
    _automatic[endpoints]?.startupSuccess = null;
    final generation = _generation;
    final flight = _flight(sdk, endpoints);
    return flight.result.then((result) {
      if (generation == _generation &&
          result is! UpdateCheckFailed &&
          endpoints.isApiReadyFor(sdk.baseUrl) &&
          flight.requestedBase == sdk.baseUrl) {
        // A fresh manual success also resolves an old pending automatic failure,
        // without creating or advancing the automatic throttle window.
        final state = _automatic[endpoints];
        if (state != null) {
          state.pendingRecovery = false;
          state.throttledRecovery = false;
        }
      }
      return result;
    });
  }

  static _UpdateFlight _flight(
    XBoardSDK sdk,
    EndpointRaceController endpoints,
  ) {
    final running = _inFlight[endpoints];
    if (running != null) return running;
    final flight = _UpdateFlight();
    _inFlight[endpoints] = flight;
    flight.result = _checkReady(sdk, endpoints, flight).whenComplete(() {
      if (identical(_inFlight[endpoints], flight)) _inFlight[endpoints] = null;
    });
    return flight;
  }

  static Future<UpdateCheckResult> _checkReady(
    XBoardSDK sdk,
    EndpointRaceController endpoints,
    _UpdateFlight flight,
  ) async {
    try {
      if (!await endpoints.waitForApiReady() ||
          !endpoints.isApiReadyFor(sdk.baseUrl)) {
        return UpdateCheckFailed(StateError('API is not ready'));
      }
      // 编译期注入的原始 build number（不受 ABI split 前缀影响）。
      const buildNumber = int.fromEnvironment(
        'XB_BUILD_NUMBER',
        defaultValue: 0,
      );
      const currentCode = buildNumber;
      debugPrint(
        '[XbUpdateService] currentCode=$currentCode (dart-define XB_BUILD_NUMBER)',
      );
      final abi = await _resolveAbi();

      if (!endpoints.isApiReadyFor(sdk.baseUrl)) {
        return UpdateCheckFailed(StateError('API is not ready'));
      }
      final attemptedBase = sdk.baseUrl;
      AppUpdateModel? info;
      try {
        flight.requestedBase = sdk.baseUrl;
        info = await sdk.appUpdate.checkUpdate(
          platform: _platform,
          abi: abi,
          currentVersionCode: currentCode,
        );
      } catch (e) {
        // 首次请求失败 → 尝试 failover 切域名后重试一次。
        if (endpoints.isApiReadyFor(sdk.baseUrl)) {
          debugPrint(
            '[XbUpdateService] first attempt failed ($e), trying failover...',
          );
          if (sdk.baseUrl == attemptedBase) await endpoints.failOverApi();
          if (!endpoints.isApiReadyFor(sdk.baseUrl) ||
              sdk.baseUrl == attemptedBase) {
            return UpdateCheckFailed(e);
          }
          flight.requestedBase = sdk.baseUrl;
          info = await sdk.appUpdate.checkUpdate(
            platform: _platform,
            abi: abi,
            currentVersionCode: currentCode,
          );
        } else {
          rethrow;
        }
      }

      debugPrint(
        '[XbUpdateService] response: info=${info == null ? "null" : "versionCode=${info.versionCode}"}',
      );

      if (info == null) return UpdateNotAvailable();

      // 服务端 versionCode > 本地 → 有更新
      debugPrint(
        '[XbUpdateService] compare: ${info.versionCode} > $currentCode = ${info.versionCode > currentCode}',
      );
      if (info.versionCode > currentCode) {
        return UpdateAvailable(info, currentCode);
      }
      return UpdateNotAvailable();
    } catch (e, s) {
      debugPrint('[XbUpdateService] check failed: $e\n$s');
      return UpdateCheckFailed(e);
    }
  }

  /// Cold startup retains its independent, unthrottled trigger.
  static Future<void> autoCheck(ProviderContainer container) =>
      _automaticCheck(container, throttled: false);

  /// Called after the SDK has applied an API winner. Only a previously pending
  /// automatic check may recover; ordinary manual failover creates no trigger.
  static void onApiAvailable(ProviderContainer container) {
    final sdk = container.read(xboardSdkProvider);
    final race = container.read(injectedRaceControllerProvider);
    if (sdk == null || race == null) return;
    final state = _automatic[race];
    if (state != null) {
      state.startupSuccess = null;
      _recoverIfChanged(container, sdk, race, state);
    }
  }

  static void _recoverIfChanged(
    ProviderContainer container,
    XBoardSDK sdk,
    EndpointRaceController race,
    _AutomaticUpdateState state,
  ) {
    if (!state.pendingRecovery ||
        state.running != 0 ||
        !race.isApiReadyFor(sdk.baseUrl) ||
        sdk.baseUrl == state.failedBase) {
      return;
    }
    // The async function registers itself before its first await. Simultaneous
    // winner notifications cannot enqueue multiple recovery requests.
    unawaited(_automaticCheck(container, throttled: state.throttledRecovery));
  }

  static Future<void> _automaticCheck(
    ProviderContainer container, {
    required bool throttled,
  }) async {
    if (throttled) {
      if (container.read(availableUpdateProvider) != null || _checking) return;
      final sw = _throttle;
      if (sw != null && sw.elapsed < kCheckThrottle) return;
    }
    final sdk = container.read(xboardSdkProvider);
    final race = container.read(injectedRaceControllerProvider);
    if (sdk == null || race == null) return;
    if (throttled) _checking = true;
    final generation = _generation;
    final state = _automatic[race] ??= _AutomaticUpdateState();
    state.running++;
    state.throttledRecovery |= throttled;
    try {
      final cached = state.startupSuccess;
      UpdateCheckResult result;
      String? requestedBase;
      if (race.apiInitializationPending &&
          cached != null &&
          race.isApiReadyFor(sdk.baseUrl) &&
          cached.base == sdk.baseUrl) {
        result = cached.result;
        requestedBase = cached.base;
      } else {
        state.startupSuccess = null;
        final flight = _flight(sdk, race);
        result = await flight.result;
        requestedBase = flight.requestedBase;
      }
      if (generation != _generation) return;
      final valid =
          race.isApiReadyFor(sdk.baseUrl) && requestedBase == sdk.baseUrl;
      if (result is UpdateCheckFailed || !valid) {
        state.pendingRecovery = true;
        state.throttledRecovery |= throttled;
        state.failedBase = requestedBase;
        state.startupSuccess = null;
        return;
      }
      state.pendingRecovery = false;
      state.throttledRecovery = false;
      state.startupSuccess = race.apiInitializationPending
          ? _StartupSuccess(result, requestedBase!)
          : null;
      if (result is UpdateAvailable) {
        container.read(availableUpdateProvider.notifier).set(result.info);
      }
      if (throttled) _throttle = _createStopwatch()..start();
    } finally {
      state.running--;
      if (generation == _generation) {
        if (throttled) _checking = false;
        _recoverIfChanged(container, sdk, race, state);
      }
    }
  }

  // ───────── 触发时机 + 24h 节流（全异步 fire-and-forget，绝不阻塞）─────────

  /// 24h 节流单调时钟（θ-7：距上次成功检查 ≥24h 才真请求；防改系统时间绕过）。
  /// null = 从未检查过（首次直接放行）。
  static Stopwatch? _throttle;
  static Stopwatch Function() _createStopwatch = Stopwatch.new;

  /// 注入单调计时器以覆盖 24h 临界点；生产仍使用真实 Stopwatch。
  @visibleForTesting
  static void debugSetStopwatchFactory(Stopwatch Function()? factory) {
    resetThrottle();
    _createStopwatch = factory ?? Stopwatch.new;
  }

  /// single-flight：检查进行中标志，避免并发请求。
  static bool _checking = false;
  static int _generation = 0;

  /// 节流检查窗口（24h，与订阅同节奏）。
  static const Duration kCheckThrottle = Duration(hours: 24);

  /// 节流自动检查（onResume / VPN 连上触发）：距上次成功检查 ≥24h 才真请求。
  ///
  /// fire-and-forget，永不抛、永不阻塞。已有可用更新时跳过（已点亮徽章，无需重查）。
  static Future<void> autoCheckThrottled(ProviderContainer container) =>
      _automaticCheck(container, throttled: true);

  /// 重置节流时钟（退出登录 / 测试 teardown）。
  static void resetThrottle() {
    _generation++;
    _inFlight = Expando<_UpdateFlight>();
    _automatic = Expando<_AutomaticUpdateState>();
    _throttle = null;
    _checking = false;
  }

  /// 当前平台标识（后端 API 接受的 platform 参数）。
  static String get _platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// 当前设备 ABI（后端 API 接受的 abi 参数）。
  ///
  /// Android：构建脚本注入（arm64-v8a / armeabi-v7a / x86_64）。
  /// 桌面：真实检测 CPU 架构——Windows 读 env（WOW64 下 `PROCESSOR_ARCHITEW6432` 反映真实
  /// 架构，x64 进程跑在 ARM64 上时）；Linux/macOS 跑 `uname -m`（aarch64/arm64 → arm64，
  /// 否则 x64）。检测失败兜底 x64。
  static Future<String> _resolveAbi() async {
    if (Platform.isAndroid) {
      return const String.fromEnvironment(
        'XB_ANDROID_ABI',
        defaultValue: 'arm64-v8a',
      );
    }
    if (Platform.isWindows) {
      final env = Platform.environment;
      final arch =
          (env['PROCESSOR_ARCHITEW6432'] ?? env['PROCESSOR_ARCHITECTURE'] ?? '')
              .toUpperCase();
      return arch.contains('ARM64') ? 'arm64' : 'x64';
    }
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        final r = await Process.run('uname', ['-m']);
        final m = (r.stdout as String).trim().toLowerCase();
        return (m == 'aarch64' || m == 'arm64') ? 'arm64' : 'x64';
      } catch (_) {
        return 'x64';
      }
    }
    return 'x64';
  }
}
