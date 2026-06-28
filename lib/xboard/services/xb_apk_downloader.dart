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
///    - Windows：`Process.start` 拉起 .exe 安装器（Inno 脚本会先杀进程再覆盖），调用方随后退出
///    - Linux：用新 AppImage 覆盖当前 `$APPIMAGE` 文件 + chmod + 拉起新进程，调用方随后退出
/// 4. 任何步骤失败 → 返回对应 [DownloadResult]（调用方回退到档1 浏览器）
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'sentry_bootstrap.dart';
import 'xboard_release_dio.dart';

/// 下载进度回调。
typedef DownloadProgress = void Function(int received, int total);

/// 下载结果。
enum DownloadResult { success, hashMismatch, networkError, installFailed }

class XbApkDownloader {
  XbApkDownloader._();

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
  /// 返回 [DownloadResult]。Windows/Linux 成功后调用方应退出进程让安装器/新进程接管。
  static Future<DownloadResult> downloadAndInstall({
    required List<String> urls,
    required String expectedSha256,
    required DownloadProgress onProgress,
    CancelToken? cancelToken,
  }) async {
    if (urls.isEmpty) return DownloadResult.networkError;
    if (!isInAppInstallSupported) return DownloadResult.installFailed;

    // 确定保存目录 + 文件名（按平台扩展名）。
    final Directory baseDir;
    if (Platform.isAndroid) {
      final cacheDir = await getExternalCacheDirectories();
      baseDir = cacheDir?.firstOrNull ?? await getTemporaryDirectory();
    } else {
      baseDir = await getTemporaryDirectory();
    }
    final updateDir = Directory('${baseDir.path}/update');
    if (!updateDir.existsSync()) updateDir.createSync(recursive: true);
    final fileName = _updateFileName();
    final filePath = '${updateDir.path}/$fileName';

    // 清理旧文件
    final oldFile = File(filePath);
    if (oldFile.existsSync()) oldFile.deleteSync();

    // 逐源尝试下载。复用项目放行 dio（R4.4：浏览器 UA 伪装 + 证书放行 + 直连，与
    // bootstrap / 加密订阅同款抗封锁链路）；connectTimeout 5s 快速切换死源，
    // 大文件下载单独放宽 receiveTimeout 到 5 分钟。
    final dio = buildReleasedIsolatedDio(timeout: const Duration(seconds: 5))
      ..options.receiveTimeout = const Duration(minutes: 5);

    bool downloaded = false;
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
        final partial = File(filePath);
        if (partial.existsSync()) partial.deleteSync();
        continue;
      }
    }
    dio.close();

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
            '[XbApkDownloader] SHA256 mismatch: expected=$expectedSha256, got=$hash');
        file.deleteSync();
        // #2 监测：hash 不符 = 下载损坏 / 后台配错 sha256 / 潜在篡改 → 高价值，必报。
        SentryBootstrap.captureException(
          'self-update SHA256 mismatch (expected=$expectedSha256 got=$hash)',
          where: 'self-update hash mismatch',
        );
        return DownloadResult.hashMismatch;
      }
    }

    // 按平台安装
    if (Platform.isAndroid) return _installAndroid(filePath);
    if (Platform.isWindows) return _installWindows(filePath);
    if (Platform.isLinux) return _installLinux(filePath);
    return DownloadResult.installFailed;
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
      SentryBootstrap.captureException(e,
          stackTrace: s, where: 'self-update install (android)');
      return DownloadResult.installFailed;
    }
  }

  /// Windows：拉起 Inno Setup .exe 安装器（脚本内 KillProcesses 会先杀运行中的程序再覆盖）。
  /// detached 启动后返回 success；调用方随后退出本进程，让安装器接管。
  static Future<DownloadResult> _installWindows(String filePath) async {
    try {
      await Process.start(
        filePath,
        const [], // 交互式安装（与 FlClash 安装器一致，用户可见进度/确认）。
        mode: ProcessStartMode.detached,
      );
      return DownloadResult.success;
    } catch (e, s) {
      debugPrint('[XbApkDownloader] windows installer launch failed: $e');
      SentryBootstrap.captureException(e,
          stackTrace: s, where: 'self-update install (windows)');
      return DownloadResult.installFailed;
    }
  }

  /// Linux（AppImage）：用新 AppImage 覆盖当前运行的 `$APPIMAGE` 文件 → chmod +x → 拉起新进程。
  /// 仅在以 AppImage 形式运行时可行（环境变量 `APPIMAGE` 存在）；否则返回 installFailed（走浏览器）。
  static Future<DownloadResult> _installLinux(String downloadedPath) async {
    final appImagePath = Platform.environment['APPIMAGE'];
    if (appImagePath == null || appImagePath.isEmpty) {
      debugPrint('[XbApkDownloader] not running as AppImage（无 \$APPIMAGE）→ 回退浏览器');
      return DownloadResult.installFailed;
    }
    try {
      final target = File(appImagePath);
      if (!target.existsSync()) return DownloadResult.installFailed;
      // ⚠️ 不能直接覆盖正在运行的 AppImage：Linux 对运行中可执行文件 open(O_TRUNC) 写入
      // 会报 ETXTBSY（text file busy）。改用「同目录写 stage 文件 → chmod → 原子 rename 替换」：
      // rename 不打开运行中文件，运行中进程仍持旧 inode（安全），新进程将加载新文件。
      // rename 要求同一文件系统，故 stage 必须落在 $APPIMAGE 同目录（不能用 /tmp 跨 fs）。
      final stagePath = '${target.parent.path}/.xb_appimage_update.new';
      final stage = File(stagePath);
      if (stage.existsSync()) stage.deleteSync();
      await File(downloadedPath).copy(stagePath);
      // 赋可执行权限（在 stage 文件上）。
      final chmod = await Process.run('chmod', ['+x', stagePath]);
      if (chmod.exitCode != 0) {
        debugPrint('[XbApkDownloader] chmod failed: ${chmod.stderr}');
        if (stage.existsSync()) stage.deleteSync();
        return DownloadResult.installFailed;
      }
      // 原子替换正在运行的 AppImage（同 fs rename，旧 inode 由运行中进程持有不受影响）。
      await stage.rename(appImagePath);
      // 拉起新 AppImage（detached）；调用方随后退出本进程。
      // 显式传递环境变量（含 DISPLAY、WAYLAND_DISPLAY 等），
      // 确保在各种启动器环境下新进程能继承正确的显示器配置。
      await Process.start(
        appImagePath,
        const [],
        mode: ProcessStartMode.detached,
        environment: Platform.environment,
      );
      return DownloadResult.success;
    } catch (e, s) {
      debugPrint('[XbApkDownloader] linux self-update failed: $e');
      SentryBootstrap.captureException(e,
          stackTrace: s, where: 'self-update install (linux)');
      return DownloadResult.installFailed;
    }
  }
}
