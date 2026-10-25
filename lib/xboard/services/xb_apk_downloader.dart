/// 安装包下载 + 校验 + 安装服务（self-update tier-2，跨平台）。
///
/// **支持平台**：Android（APK + 系统安装器）/ Windows（Inno Setup .exe 安装器）/
/// Linux（AppImage 自替换重启）。macOS 不走本服务（由调用方回退浏览器下载）。
///
/// **流程**：
/// 1. 逐源下载到临时目录（带进度回调）
/// 2. SHA256 校验（下载完成后本地算 hash 比对）
/// 3. 按平台「应用」更新：
///    - Android：platform channel 调起系统安装器
///    - Windows：`Process.start` 拉起 .exe 安装器（安装器按品牌及目录处理旧进程），由安装器接管旧进程
///    - Linux：原子替换 AppImage，安排旧进程正常退出后启动新版
/// 4. 失败返回对应 [DownloadResult]，由界面显示重试或手动安装提示。
library;

import 'dart:io';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'sentry_bootstrap.dart';
import 'xb_appimage_install.dart';
import 'xb_update_lease.dart';
import '../storage/brand_paths.dart';
import 'xboard_release_dio.dart';

/// 下载进度回调。
typedef DownloadProgress = void Function(int received, int total);

/// 下载结果。
enum DownloadResult { success, hashMismatch, networkError, installFailed, busy }

class XbApkDownloader {
  XbApkDownloader._();

  static final _gate = XbUpdateGate();

  static const _channel = MethodChannel('com.follow.clash/apk_installer');

  /// 当前平台是否支持应用内下载安装（Android/Windows/Linux）。macOS/其它 → false（调用方走浏览器）。
  static bool get isInAppInstallSupported =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  /// 下载 → 校验 → 安装。
  ///
  /// [urls] — 按优先级排好的下载源列表（已按 region 排序）。
  /// [expectedSha256] — 预期 SHA256（小写 hex）。空串跳过校验。
  /// [onProgress] — 进度回调（received, total bytes）。
  /// [cancelToken] — 取消令牌。
  ///
  /// Windows 成功后保留客户端，由安装器接管；Linux 成功后调用方应正常退出。
  static Future<DownloadResult> downloadAndInstall({
    required List<String> urls,
    required String expectedSha256,
    required DownloadProgress onProgress,
    CancelToken? cancelToken,
    Future<void> Function()? requestLinuxExit,
  }) async {
    final lease = _gate.acquire();
    if (lease == null) return DownloadResult.busy;
    var heldByInstaller = false;
    try {
      return await _downloadAndInstall(
        urls: urls,
        expectedSha256: expectedSha256,
        onProgress: onProgress,
        cancelToken: cancelToken,
        requestLinuxExit: requestLinuxExit,
        onWindowsStarted: (process) {
          heldByInstaller = true;
          unawaited(
            xbWaitForInstaller(process, lease).catchError((Object _) {}),
          );
        },
      );
    } catch (error, stack) {
      SentryBootstrap.captureException(
        error,
        stackTrace: stack,
        where: 'self-update preparation',
      );
      return DownloadResult.installFailed;
    } finally {
      if (!heldByInstaller) lease.release();
    }
  }

  static Future<DownloadResult> _downloadAndInstall({
    required List<String> urls,
    required String expectedSha256,
    required DownloadProgress onProgress,
    required void Function(Process) onWindowsStarted,
    CancelToken? cancelToken,
    Future<void> Function()? requestLinuxExit,
  }) async {
    if (urls.isEmpty) return DownloadResult.networkError;
    if (!isInAppInstallSupported) return DownloadResult.installFailed;

    // 确定保存目录 + 文件名（按平台扩展名）。
    final Directory baseDir;
    if (Platform.isAndroid) {
      final cacheDir = await getExternalCacheDirectories();
      baseDir = cacheDir?.firstOrNull ?? await getTemporaryDirectory();
    } else {
      baseDir = await brandTemporaryDirectory();
    }
    final updateDir = Directory('${baseDir.path}/update');
    if (!updateDir.existsSync()) updateDir.createSync(recursive: true);
    // Never delete an executable an earlier installer may still be reading.
    final taskDirectory = await updateDir.createTemp('task-');
    final filePath = '${taskDirectory.path}/${_updateFileName()}';
    var handedOff = false;
    try {
      // 与 Bootstrap/加密订阅共用工厂，继承全局代理路由与证书/UA 策略。
      // connectTimeout 5s 快速切换死源；大文件 receiveTimeout 放宽至5分钟。
      final dio = buildReleasedIsolatedDio(timeout: const Duration(seconds: 5))
        ..options.receiveTimeout = const Duration(minutes: 5);

      bool downloaded = false;
      try {
        for (final url in urls) {
          try {
            await dio.download(
              url,
              filePath,
              onReceiveProgress: onProgress,
              cancelToken: cancelToken,
            );
            downloaded = true;
            break;
          } on DioException catch (e) {
            debugPrint('[XbApkDownloader] source failed: $url → ${e.message}');
            if (CancelToken.isCancel(e)) return DownloadResult.networkError;
            final partial = File(filePath);
            if (partial.existsSync()) partial.deleteSync();
            continue;
          }
        }
      } finally {
        dio.close(force: true);
      }

      if (!downloaded) {
        // #2 监测：所有下载源都失败（每次更新仅报一次，非每源；Sentry 去重）→ 自更新档2 不可用。
        SentryBootstrap.captureException(
          'self-update download failed: all ${urls.length} source(s) unreachable',
          where: 'self-update download',
        );
        return DownloadResult.networkError;
      }

      // SHA256 校验
      if (expectedSha256.isNotEmpty) {
        final file = File(filePath);
        final bytes = await file.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        if (hash != expectedSha256.toLowerCase()) {
          debugPrint(
            '[XbApkDownloader] SHA256 mismatch: expected=$expectedSha256, got=$hash',
          );
          file.deleteSync();
          // #2 监测：hash 不符 = 下载损坏 / 后台配错 sha256 / 潜在篡改 → 高价值，必报。
          SentryBootstrap.captureException(
            'self-update SHA256 mismatch (expected=$expectedSha256 got=$hash)',
            where: 'self-update hash mismatch',
          );
          return DownloadResult.hashMismatch;
        }
      }

      if (cancelToken?.isCancelled ?? false) return DownloadResult.networkError;
      final DownloadResult result;
      if (Platform.isAndroid) {
        result = await _installAndroid(filePath);
      } else if (Platform.isWindows) {
        result = await _installWindows(filePath, onWindowsStarted);
      } else if (Platform.isLinux && requestLinuxExit != null) {
        result = await _installLinux(filePath, requestLinuxExit);
      } else {
        result = DownloadResult.installFailed;
      }
      handedOff = result == DownloadResult.success;
      return result;
    } finally {
      if (!handedOff && await taskDirectory.exists()) {
        try {
          await taskDirectory.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 临时文件名（按平台扩展名）。
  static String _updateFileName() {
    if (Platform.isWindows) return 'update.exe';
    if (Platform.isLinux) return 'update.AppImage';
    return 'update.apk';
  }

  /// Android：调 platform channel 触发系统安装器。
  static Future<DownloadResult> _installAndroid(String filePath) async {
    try {
      await _channel.invokeMethod('installApk', {'path': filePath});
      return DownloadResult.success;
    } on PlatformException catch (e, s) {
      debugPrint('[XbApkDownloader] install failed: ${e.message}');
      SentryBootstrap.captureException(
        e,
        stackTrace: s,
        where: 'self-update install (android)',
      );
      return DownloadResult.installFailed;
    }
  }

  /// Windows：拉起品牌 Inno Setup 安装器，由其按品牌及目录停止旧进程。
  /// 保留安装器进程句柄直到退出，防止重复启动；客户端由安装器准备安装时接管。
  static Future<DownloadResult> _installWindows(
    String filePath,
    void Function(Process) started,
  ) async {
    try {
      final process = await Process.start(
        filePath,
        const [], // 交互式安装（与 FlClash 安装器一致，用户可见进度/确认）。
        mode: ProcessStartMode.normal,
      );
      started(process);
      return DownloadResult.success;
    } catch (e, s) {
      debugPrint('[XbApkDownloader] windows installer launch failed: $e');
      SentryBootstrap.captureException(
        e,
        stackTrace: s,
        where: 'self-update install (windows)',
      );
      return DownloadResult.installFailed;
    }
  }

  /// Linux（AppImage）：用新 AppImage 覆盖当前运行的 `$APPIMAGE` 文件 → chmod +x → 拉起新进程。
  /// 仅在以 AppImage 形式运行时可行（环境变量 `APPIMAGE` 存在）；否则返回 installFailed（走浏览器）。
  static Future<DownloadResult> _installLinux(
    String downloadedPath,
    Future<void> Function() requestExit,
  ) async {
    final appImagePath = Platform.environment['APPIMAGE'];
    if (appImagePath == null || appImagePath.isEmpty) {
      return DownloadResult.installFailed;
    }
    try {
      await xbInstallAppImage(
        downloadedPath: downloadedPath,
        appImagePath: appImagePath,
        requestExit: requestExit,
      );
      return DownloadResult.success;
    } catch (error, stack) {
      SentryBootstrap.captureException(
        error,
        stackTrace: stack,
        where: 'self-update install (linux)',
      );
      return DownloadResult.installFailed;
    }
  }
}
