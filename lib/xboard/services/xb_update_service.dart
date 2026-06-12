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
  /// 返回 sealed [UpdateCheckResult]。调用方决定如何展示（弹窗/toast/静默）。
  static Future<UpdateCheckResult> check(XBoardSDK sdk) async {
    try {
      // 编译期注入的原始 build number（不受 ABI split 前缀影响）。
      const buildNumber = int.fromEnvironment('XB_BUILD_NUMBER', defaultValue: 0);
      final currentCode = buildNumber;
      debugPrint('[XbUpdateService] currentCode=$currentCode (dart-define XB_BUILD_NUMBER)');

      final info = await sdk.appUpdate.checkUpdate(
        platform: _platform,
        abi: _abi,
        currentVersionCode: currentCode,
      );

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
    final result = await check(sdk);
    if (result is UpdateAvailable) {
      container.read(availableUpdateProvider.notifier).set(result.info);
    }
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
