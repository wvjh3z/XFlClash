/// 更新弹窗组件（档2 app 内下载安装，失败回退档1 浏览器打开）。
///
/// 按钮即进度条：点击后品牌红从左往右填充 + 白色百分比数字。
/// 点击后独立判断地区，组内随机；不做下载地址HEAD测活。
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'package:fl_clash/providers/providers.dart' show systemActionProvider;

import 'package:fl_clash/xboard/widgets/xb_emoji_text.dart';
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show AppUpdateModel;
import 'package:url_launcher/url_launcher.dart';

import '../providers/xboard_providers.dart';
import '../services/xb_apk_downloader.dart';
import '../services/xb_update_service.dart';
import '../services/xb_update_sources.dart';
import '../services/xb_update_region.dart';
import 'xb_feedback.dart' show xbBrandColor;
import 'xb_theme.dart' show xbShowDialog, XbTokens;

/// 弹出更新弹窗（对外唯一入口）。
void showXbUpdateDialog(BuildContext context, AppUpdateModel info) {
  xbShowDialog<void>(
    context: context,
    brandColor: xbBrandColor(),
    barrierDismissible: !info.force,
    builder: (_) => _UpdateDialog(info: info),
  );
}

enum _DialogState { initial, selecting, downloading, failed }

class _UpdateDialog extends ConsumerStatefulWidget {
  const _UpdateDialog({required this.info});
  final AppUpdateModel info;

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  _DialogState _state = _DialogState.initial;
  double _progress = 0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _errorMsg;
  CancelToken? _cancelToken;
  XbUpdateRegionLookup? _regionLookup;
  bool get _busy =>
      _state == _DialogState.selecting || _state == _DialogState.downloading;

  /// 当前生效的更新信息（初始为传入值；下载前会重拉刷新，取得最新下载地址和版本信息）。
  late AppUpdateModel _info = widget.info;

  /// 节流：上次 UI 更新时间。
  DateTime _lastUiUpdate = DateTime(2000);

  @override
  void dispose() {
    _cancelToken?.cancel('dialog dismissed');
    _regionLookup?.cancel();
    super.dispose();
  }

  /// 档2：重拉最新版本信息与下载地址，下载完成后交给平台安装流程。
  /// 不在客户端比对安装包摘要；失败时保留浏览器下载入口。
  Future<void> _onUpdate() async {
    if (_busy) return;
    setState(() {
      _state = _DialogState.selecting;
      _progress = 0;
      _receivedBytes = 0;
      _totalBytes = 0;
      _errorMsg = null;
    });
    try {
      await _performUpdate();
    } on Exception {
      if (mounted) {
        setState(() {
          _state = _DialogState.failed;
          _errorMsg = '无法准备更新，请重试';
        });
      }
    }
  }

  Future<List<String>> _selectUrls() async {
    final lookup = ref.read(xbUpdateRegionLookupFactoryProvider)();
    _regionLookup = lookup;
    final country = await lookup.run();
    if (identical(_regionLookup, lookup)) _regionLookup = null;
    return xbRandomizedUpdateUrls(_info, countryCode: country);
  }

  Future<void> _performUpdate() async {
    // macOS / 不支持应用内安装的平台 → 直接走浏览器下载（不进 APK/installer 路径）。
    if (!XbApkDownloader.isInAppInstallSupported) {
      final urls = await _selectUrls();
      if (mounted) await _openBrowser(urls);
      return;
    }
    // 下载前重拉最新版本信息（带 failover）；成功则用最新版本信息/URL，失败沿用缓存（best effort）。
    final sdk = ref.read(xboardSdkProvider);
    if (sdk != null) {
      final race = ref.read(injectedRaceControllerProvider);
      final result = await XbUpdateService.check(sdk, endpoints: race);
      if (!mounted) return;
      if (result is UpdateAvailable) {
        _info = result.info;
        // 同步刷新全局 provider（徽章/关于行/下次弹窗都用最新）。
        ref.read(availableUpdateProvider.notifier).set(result.info);
      }
      // UpdateNotAvailable / 失败 → 沿用缓存 _info（best effort）。
    }

    // 按 region 排序 URL（不探活,直接传给 downloader）
    final urls = await _selectUrls();
    if (!mounted) return;
    if (urls.isEmpty) {
      await _openBrowser(urls);
      return;
    }

    setState(() => _state = _DialogState.downloading);
    _cancelToken = CancelToken();

    // Capture the long-lived action before awaiting download. Installation
    // must not depend on this dialog still being mounted at completion.
    final exitAction = Platform.isLinux
        ? ref.read(systemActionProvider.notifier)
        : null;
    final result = await XbApkDownloader.downloadAndInstall(
      requestLinuxExit: exitAction == null
          ? null
          : () => exitAction.handleExit(),
      urls: urls,
      onProgress: (received, total) {
        if (!mounted) return;
        // 节流：100ms 内只更新一次 UI
        final now = DateTime.now();
        if (now.difference(_lastUiUpdate).inMilliseconds < 100) return;
        _lastUiUpdate = now;
        setState(() {
          _receivedBytes = received;
          _totalBytes = total;
          _progress = total > 0 ? received / total : 0;
        });
      },
      cancelToken: _cancelToken,
    );

    if (!mounted) return;

    switch (result) {
      case DownloadResult.success:
        // Windows follows upstream: the interactive installer owns shutdown.
        // Cancelling its UAC/wizard must not make this client exit prematurely.
        if (Platform.isLinux) return;
        // Android：安装器已调起，延迟关弹窗（给系统时间展示安装界面）
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.of(context).pop();
      case DownloadResult.networkError:
        setState(() {
          _state = _DialogState.failed;
          _errorMsg = '下载失败，网络异常';
        });
      case DownloadResult.busy:
        setState(() {
          _state = _DialogState.failed;
          _errorMsg = '更新正在进行，请先完成或关闭已打开的安装器';
        });
      case DownloadResult.installFailed:
        setState(() {
          _state = _DialogState.failed;
          _errorMsg = '安装启动失败，请手动安装';
        });
    }
  }

  /// 档1 兜底：浏览器打开。
  Future<void> _fallbackToBrowser() async {
    if (_busy) return;
    setState(() {
      _state = _DialogState.selecting;
      _errorMsg = null;
    });
    final urls = await _selectUrls();
    if (mounted) await _openBrowser(urls);
  }

  Future<void> _openBrowser(List<String> urls) async {
    final opened = await xbOpenUpdateDownload(
      _info,
      orderedUrls: urls,
      open: (uri) async {
        if (!mounted) return false;
        return launchUrl(uri, mode: LaunchMode.externalApplication);
      },
    );
    if (!mounted) return;
    if (opened) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _state = _DialogState.failed;
      _errorMsg = '无法打开下载链接，请重试';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    // 下载中禁止「点外部 / 返回键」关闭弹窗（否则误触会触发 dispose→cancelToken.cancel 取消下载）。
    // barrier-tap 走 Navigator.maybePop（受 PopScope 约束），按钮用的直接 Navigator.pop 不受影响。
    // 初始/失败态 canPop=true，非强制更新仍可点外部「稍后再说」。
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            XbEmojiText(
              '🎉 发现新版本',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${_info.versionName} 可用',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        content: _buildContent(t, scheme),
      ),
    );
  }

  Widget _buildContent(XbTokens t, ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Changelog（自适应高度，跟随内容量变化；超长时内部可滚动，最高 160）
        if (_info.changelog.isNotEmpty)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 160),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.sf,
              borderRadius: BorderRadius.circular(XbTokens.rSm),
            ),
            child: SingleChildScrollView(
              child: XbEmojiText(
                _info.changelog,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 2,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
        const SizedBox(height: 14),
        // 固定高度底部区：按钮/进度/spinner/错误都在此切换，弹窗总高不变。
        SizedBox(height: 72, child: Center(child: _buildFooter(t, scheme))),
      ],
    );
  }

  /// 底部区内容（随状态变化，但容器高度固定 72）。
  Widget _buildFooter(XbTokens t, ColorScheme scheme) {
    switch (_state) {
      case _DialogState.initial:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _initialButtons(t),
            if (_info.force)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '此为重要更新，必须更新后使用',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: scheme.error,
                  ),
                ),
              ),
          ],
        );
      case _DialogState.selecting:
      case _DialogState.downloading:
        return _downloadingFooter(scheme);
      case _DialogState.failed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_errorMsg != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _errorMsg!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ),
            _failedButtons(t),
          ],
        );
    }
  }

  Widget _initialButtons(XbTokens t) {
    return Row(
      children: [
        if (!_info.force)
          Expanded(
            child: SizedBox(
              height: 46,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: t.sfc,
                  foregroundColor: t.on,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(XbTokens.rMd),
                  ),
                ),
                child: const Text('以后再说'),
              ),
            ),
          ),
        if (!_info.force) const SizedBox(width: 11),
        Expanded(
          child: SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: _onUpdate,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(XbTokens.rMd),
                ),
              ),
              child: const Text('立即更新'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _failedButtons(XbTokens t) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: _fallbackToBrowser,
              style: FilledButton.styleFrom(
                backgroundColor: t.sfc,
                foregroundColor: t.on,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(XbTokens.rMd),
                ),
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '浏览器下载',
                  maxLines: 1,
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: _onUpdate,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(XbTokens.rMd),
                ),
              ),
              child: const Text('重试'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _downloadingFooter(ColorScheme scheme) {
    final pct = (_progress * 100).toInt();
    final hasProgress = _state != _DialogState.selecting && _progress > 0;
    if (!hasProgress) {
      // 未收到进度：spinner + 文字（琥珀色，居中）
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: XbTokens.warn,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _state == _DialogState.selecting ? '选择线路中…' : '正在准备下载…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      );
    }
    // 原型 15f2：胶囊进度条(品牌红填充 + 内嵌白字百分比) + 下方「正在下载 · 已下载/总大小」
    final receivedMb = (_receivedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = _totalBytes > 0
        ? (_totalBytes / (1024 * 1024)).toStringAsFixed(1)
        : '?';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 胶囊进度条：双层百分比（底层品牌红字 + 上层白字按进度裁剪），任何进度都清晰可读。
        SizedBox(
          width: double.infinity,
          height: 28,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                // 底：浅红槽 + 居中品牌红百分比（未填充区域看这层，红字浅底 → 清晰）
                Positioned.fill(
                  child: Container(
                    color: scheme.primary.withValues(alpha: 0.1),
                  ),
                ),
                Center(
                  child: Text(
                    '$pct%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
                // 上：红色填充 + 居中白色百分比，整体按进度宽度从左裁剪。
                // 文字全宽居中布局，与底层完全重合 → 被裁掉的部分露出底层红字。
                Positioned.fill(
                  child: ClipRect(
                    clipper: _ProgressClipper(_progress.clamp(0.0, 1.0)),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  scheme.primary,
                                  scheme.primary.withValues(alpha: 0.85),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Center(
                          child: Text(
                            '$pct%',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '正在下载 · $receivedMb / $totalMb MB',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 进度裁剪器：从左裁剪到 [progress] 宽度（用于进度条上层白字+红填充的可见区域）。
class _ProgressClipper extends CustomClipper<Rect> {
  _ProgressClipper(this.progress);
  final double progress;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * progress, size.height);

  @override
  bool shouldReclip(_ProgressClipper old) => old.progress != progress;
}
