/// APK 下载 + 校验 + 安装服务（self-update tier-2）。
///
/// **流程**:
/// 1. 探活选源（HEAD probe，复用更新弹窗逻辑传入 URL）
/// 2. dio 下载到 external cache dir `/update/xxx.apk`，带进度回调
/// 3. SHA256 校验（下载完成后本地算 hash 比对）
/// 4. 调 platform channel 触发系统安装器
/// 5. 任何步骤失败 → 回调 onFailed（调用方回退到档1）
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 下载进度回调。
typedef DownloadProgress = void Function(int received, int total);

/// 下载结果。
enum DownloadResult { success, hashMismatch, networkError, installFailed }

class XbApkDownloader {
  XbApkDownloader._();

  static const _channel = MethodChannel('com.follow.clash/apk_installer');

  /// 下载 → 校验 → 安装。
  ///
  /// [urls] — 按优先级排好的下载源列表（已探活或按 region 排序）。
  /// [expectedSha256] — 预期 SHA256（小写 hex）。空串跳过校验。
  /// [onProgress] — 进度回调（received, total bytes）。
  /// [cancelToken] — 取消令牌。
  ///
  /// 返回 [DownloadResult]。
  static Future<DownloadResult> downloadAndInstall({
    required List<String> urls,
    required String expectedSha256,
    required DownloadProgress onProgress,
    CancelToken? cancelToken,
  }) async {
    if (urls.isEmpty) return DownloadResult.networkError;

    // 确定保存路径
    final cacheDir = await getExternalCacheDirectories();
    final baseDir = cacheDir?.firstOrNull ?? await getTemporaryDirectory();
    final updateDir = Directory('${baseDir.path}/update');
    if (!updateDir.existsSync()) updateDir.createSync(recursive: true);
    final filePath = '${updateDir.path}/update.apk';

    // 清理旧文件
    final oldFile = File(filePath);
    if (oldFile.existsSync()) oldFile.deleteSync();

    // 逐源尝试下载
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
    ));

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
        // 清理半成品
        final partial = File(filePath);
        if (partial.existsSync()) partial.deleteSync();
        continue;
      }
    }
    dio.close();

    if (!downloaded) return DownloadResult.networkError;

    // SHA256 校验
    if (expectedSha256.isNotEmpty) {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      if (hash != expectedSha256) {
        debugPrint(
            '[XbApkDownloader] SHA256 mismatch: expected=$expectedSha256, got=$hash');
        file.deleteSync();
        return DownloadResult.hashMismatch;
      }
    }

    // 触发安装
    try {
      await _channel.invokeMethod('installApk', {'path': filePath});
      return DownloadResult.success;
    } on PlatformException catch (e) {
      debugPrint('[XbApkDownloader] install failed: ${e.message}');
      return DownloadResult.installFailed;
    }
  }
}
