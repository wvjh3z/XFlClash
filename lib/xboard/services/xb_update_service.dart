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

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show AppUpdateModel, XBoardSDK;

import '../providers/xboard_providers.dart';

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

class XbUpdateService {
  XbUpdateService._();

  /// 执行一次更新检查。
  ///
  /// [sdk] — 已 initialize 的 SDK 实例。
  /// [apiFailover] — 可选,域名故障转移函数(来自竞速控制器)。请求失败时
  /// 自动切到备用域名重试一次。
  /// 返回 sealed [UpdateCheckResult]。调用方决定如何展示（弹窗/toast/静默）。
  static Future<UpdateCheckResult> check(XBoardSDK sdk, {
    Future<void> Function()? apiFailover,
  }) async {
    try {
      // 编译期注入的原始 build number（不受 ABI split 前缀影响）。
      const buildNumber = int.fromEnvironment('XB_BUILD_NUMBER', defaultValue: 0);
      const currentCode = buildNumber;
      debugPrint('[XbUpdateService] currentCode=$currentCode (dart-define XB_BUILD_NUMBER)');

      AppUpdateModel? info;
      try {
        info = await sdk.appUpdate.checkUpdate(
          platform: _platform,
          abi: _abi,
          currentVersionCode: currentCode,
        );
      } catch (e) {
        // 首次请求失败 → 尝试 failover 切域名后重试一次。
        if (apiFailover != null) {
          debugPrint('[XbUpdateService] first attempt failed ($e), trying failover...');
          await apiFailover();
          info = await sdk.appUpdate.checkUpdate(
            platform: _platform,
            abi: _abi,
            currentVersionCode: currentCode,
          );
        } else {
          rethrow;
        }
      }

      debugPrint('[XbUpdateService] response: info=${info == null ? "null" : "versionCode=${info.versionCode}"}');

      if (info == null) return UpdateNotAvailable();

      // 服务端 versionCode > 本地 → 有更新
      debugPrint('[XbUpdateService] compare: ${info.versionCode} > $currentCode = ${info.versionCode > currentCode}');
      if (info.versionCode > currentCode) {
        return UpdateAvailable(info, currentCode);
      }
      return UpdateNotAvailable();
    } catch (e, s) {
      debugPrint('[XbUpdateService] check failed: $e\n$s');
      return UpdateCheckFailed(e);
    }
  }

  /// 冷启动自动检查（fire-and-forget，静默写 provider）。
  static Future<void> autoCheck(ProviderContainer container) async {
    final sdk = container.read(xboardSdkProvider);
    if (sdk == null) return;
    final race = container.read(injectedRaceControllerProvider);
    final result = await check(sdk, apiFailover: race?.failOverApi);
    if (result is UpdateAvailable) {
      container.read(availableUpdateProvider.notifier).set(result.info);
    }
  }

  // ───────── 触发时机 + 24h 节流（全异步 fire-and-forget，绝不阻塞）─────────

  /// 24h 节流单调时钟（θ-7：距上次成功检查 ≥24h 才真请求；防改系统时间绕过）。
  /// null = 从未检查过（首次直接放行）。
  static Stopwatch? _throttle;

  /// single-flight：检查进行中标志，避免并发请求。
  static bool _checking = false;

  /// 节流检查窗口（24h，与订阅同节奏）。
  static const Duration kCheckThrottle = Duration(hours: 24);

  /// 节流自动检查（onResume / VPN 连上触发）：距上次成功检查 ≥24h 才真请求。
  ///
  /// fire-and-forget，永不抛、永不阻塞。已有可用更新时跳过（已点亮徽章，无需重查）。
  static Future<void> autoCheckThrottled(ProviderContainer container) async {
    // 已检测到更新 → 无需重查（徽章已亮）。
    if (container.read(availableUpdateProvider) != null) return;
    if (_checking) return; // single-flight
    final sw = _throttle;
    if (sw != null && sw.elapsed < kCheckThrottle) return; // 节流窗口内

    _checking = true;
    try {
      final sdk = container.read(xboardSdkProvider);
      if (sdk == null) return;
      final race = container.read(injectedRaceControllerProvider);
      final result = await check(sdk, apiFailover: race?.failOverApi);
      if (result is UpdateAvailable) {
        container.read(availableUpdateProvider.notifier).set(result.info);
        _throttle = Stopwatch()..start(); // 成功且有更新 → 重置节流时钟
      } else if (result is UpdateNotAvailable) {
        _throttle = Stopwatch()..start(); // 成功但无更新 → 也重置（避免频繁查）
      }
      // 检查失败（网络/被墙）→ 不重置时钟，下次触发仍可重试
    } finally {
      _checking = false;
    }
  }

  /// 重置节流时钟（退出登录 / 测试 teardown）。
  static void resetThrottle() {
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
  static String get _abi {
    if (Platform.isAndroid) {
      // 构建脚本注入（arm64-v8a / armeabi-v7a / x86_64）
      const abi =
          String.fromEnvironment('XB_ANDROID_ABI', defaultValue: 'arm64-v8a');
      return abi;
    }
    // 桌面按编译目标
    return 'x64';
  }
}
