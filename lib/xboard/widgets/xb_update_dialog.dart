/// 更新弹窗组件（档2 app 内下载安装，失败回退档1 浏览器打开）。
///
/// 按钮即进度条：点击后品牌红从左往右填充 + 白色百分比数字。
/// 点击后独立判断地区，组内随机并做有界GET轻探测；不做HEAD或安装包hash校验。
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
import '../providers/xboard_connectivity_provider.dart';
import '../services/xb_apk_downloader.dart';
import '../services/xb_update_service.dart';
import '../services/xb_update_sources.dart';
import '../services/xb_update_region.dart';
import '../services/xb_update_probe.dart';
import 'xb_ui_kit.dart' show XbGradientAction;
import 'xb_feedback.dart' show xbBrandColor;
import 'xb_theme.dart' show xbShowDialog, XbTokens;

/// 弹出更新弹窗（对外唯一入口）。
Future<void> showXbUpdateDialog(BuildContext context, AppUpdateModel info) async {
  await xbShowDialog<void>(
    context: context,
    brandColor: xbBrandColor(),
    barrierDismissible: !info.force,
    builder: (_) => _UpdateDialog(info: info),
  );
}

final xbInAppUpdateSupportedProvider = Provider<bool>(
  (_) => XbApkDownloader.isInAppInstallSupported,
);

typedef XbUpdateDownload = Future<DownloadResult> Function({
  required List<String> urls,
  required DownloadProgress onProgress,
  CancelToken? cancelToken,
  Future<void> Function()? requestLinuxExit,
});

final xbUpdateDownloadProvider = Provider<XbUpdateDownload>(
  (_) => XbApkDownloader.downloadAndInstall,
);

enum _DialogState { initial, mobileConsent, selecting, downloading, handedOff, failed, browser }

class _UpdateDialog extends ConsumerStatefulWidget {
  const _UpdateDialog({required this.info});
  final AppUpdateModel info;

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  _DialogState _state = _DialogState.initial;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _errorMsg;
  CancelToken? _cancelToken;
  XbUpdateRegionLookup? _regionLookup;
  XbUpdateSourceProbe? _sourceProbe;
  List<String> _browserUrls = const [];
  int _browserIndex = 0;
  bool _browserOpening = false;
  bool _switchingBrowserSource = false;
  bool _transferActive = false;
  bool _mobileAllowed = false;
  String? _interrupted;
  String? _browserMessage;
  bool get _busy =>
      _state == _DialogState.selecting || _state == _DialogState.downloading ||
      _state == _DialogState.handedOff || _browserOpening;

  /// 当前生效的更新信息（初始为传入值；下载前会重拉刷新，取得最新下载地址和版本信息）。
  late AppUpdateModel _info = widget.info;

  Timer? _progressPaint;

  @override
  void dispose() {
    _progressPaint?.cancel();
    _cancelToken?.cancel('dialog dismissed');
    _regionLookup?.cancel();
    _sourceProbe?.cancel();
    super.dispose();
  }

  static bool _offline(List<ConnectivityResult>? links) =>
      links != null && links.isNotEmpty && links.every((v) => v == ConnectivityResult.none);

  // Mobile may appear alongside VPN/Wi-Fi. Unknown and VPN-only cannot
  // establish that the underlying route is unmetered either.
  static bool _needsDataConsent(List<ConnectivityResult>? links) =>
      links == null || links.contains(ConnectivityResult.mobile) ||
      (!links.contains(ConnectivityResult.wifi) && !links.contains(ConnectivityResult.ethernet));

  /// 档2：重拉最新清单。保持安装校验策略，失败时保留浏览器下载入口。
  Future<void> _onUpdate({bool allowMobile = false}) async {
    if (_busy) return;
    final links = ref.read(xboardConnectivityProvider).asData?.value;
    if (_offline(links)) {
      setState(() {
        _state = _DialogState.failed;
        _errorMsg = '当前无网络，请联网后重试。';
      });
      return;
    }
    _transferActive = ref.read(xbInAppUpdateSupportedProvider);
    if (_transferActive && _needsDataConsent(links) && !allowMobile) {
      _transferActive = false;
      setState(() => _state = _DialogState.mobileConsent);
      return;
    }
    _mobileAllowed = allowMobile && _needsDataConsent(links);
    _interrupted = null;
    setState(() {
      _state = _DialogState.selecting;
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
          _errorMsg = _interrupted ?? '无法准备更新，请重试';
        });
      }
    } finally {
      _transferActive = false;
      if (mounted && _interrupted != null && _state == _DialogState.selecting) {
        setState(() {
          _state = _DialogState.failed;
          _errorMsg = _interrupted;
        });
      }
    }
  }

  Future<List<String>> _selectUrls() async {
    final lookup = ref.read(xbUpdateRegionLookupFactoryProvider)();
    _regionLookup = lookup;
    final country = await lookup.run();
    if (identical(_regionLookup, lookup)) _regionLookup = null;
    if (!mounted || (_transferActive && _interrupted != null)) return const [];
    final urls = xbRandomizedUpdateUrls(_info, countryCode: country);
    if (urls.isEmpty) return urls;
    final probe = ref.read(xbUpdateSourceProbeFactoryProvider)();
    _sourceProbe = probe;
    final ordered = await probe.run(urls);
    if (identical(_sourceProbe, probe)) _sourceProbe = null;
    return ordered;
  }

  Future<void> _performUpdate() async {
    // macOS / 不支持应用内安装的平台 → 直接走浏览器下载（不进 APK/installer 路径）。
    if (!ref.read(xbInAppUpdateSupportedProvider)) {
      final urls = await _selectUrls();
      if (mounted) await _openBrowser(urls);
      return;
    }
    // 下载前重拉最新版本信息（带 failover）；成功则用最新版本信息/URL，失败沿用缓存（best effort）。
    final sdk = ref.read(xboardSdkProvider);
    if (sdk != null) {
      final race = ref.read(injectedRaceControllerProvider);
      final result = await XbUpdateService.check(sdk, endpoints: race);
      if (!mounted || _interrupted != null) return;
      if (result is UpdateAvailable) {
        _info = result.info;
        // 同步刷新全局 provider（徽章/关于行/下次弹窗都用最新）。
        ref.read(availableUpdateProvider.notifier).set(result.info, prompt: false);
      }
      // UpdateNotAvailable / 失败 → 沿用缓存 _info（best effort）。
    }

    // 地区优先/组内随机后做有界GET；确认可访问的源优先，其他源保留为后备。
    final urls = await _selectUrls();
    if (!mounted || _interrupted != null) return;
    if (urls.isEmpty) {
      await _openBrowser(urls);
      return;
    }

    setState(() => _state = _DialogState.downloading);
    final token = CancelToken();
    _cancelToken = token;

    // Capture the long-lived action before awaiting download. Installation
    // must not depend on this dialog still being mounted at completion.
    final exitAction = Platform.isLinux
        ? ref.read(systemActionProvider.notifier)
        : null;
    final DownloadResult result;
    try {
      result = await ref.read(xbUpdateDownloadProvider)(
        requestLinuxExit: exitAction == null ? null : () => exitAction.handleExit(),
        urls: urls,
        onProgress: (received, total) => _recordProgress(token, received, total),
        cancelToken: token,
      );
    } finally {
      _progressPaint?.cancel();
      _progressPaint = null;
      _cancelToken = null;
    }

    if (!mounted) return;

    switch (result) {
      case DownloadResult.success:
        setState(() => _state = _DialogState.handedOff);
        // Windows follows upstream: the interactive installer owns shutdown.
        // Cancelling its UAC/wizard must not make this client exit prematurely.
        if (Platform.isLinux) return;
        // Android：安装器已调起，延迟关弹窗（给系统时间展示安装界面）
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.of(context).pop();
      case DownloadResult.networkError:
        setState(() {
          _state = _DialogState.failed;
          _errorMsg = _interrupted ?? '下载失败，网络异常';
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

  void _recordProgress(CancelToken token, int received, int total) {
    if (!mounted || token.isCancelled || !identical(token, _cancelToken)) return;
    final changedPhase = total != _totalBytes ||
        (_receivedBytes == 0 && received > 0) ||
        received < _receivedBytes || (total > 0 && received >= total);
    _receivedBytes = received;
    _totalBytes = total;
    if (changedPhase) {
      _progressPaint?.cancel();
      _progressPaint = null;
      setState(() {});
    } else {
      // 合并中间样本，但保留最后一笔；服务器暂时不再发送也能显示已收字节。
      _progressPaint ??= Timer(const Duration(milliseconds: 100), () {
        _progressPaint = null;
        if (mounted && identical(token, _cancelToken)) setState(() {});
      });
    }
  }

  /// 档1 兜底：浏览器打开。
  Future<void> _fallbackToBrowser() async {
    if (_busy) return;
    if (_offline(ref.read(xboardConnectivityProvider).asData?.value)) {
      setState(() => _errorMsg = '当前无网络，请联网后再打开浏览器下载。');
      return;
    }
    setState(() {
      _state = _DialogState.selecting;
      _errorMsg = null;
    });
    final urls = await _selectUrls();
    if (mounted) await _openBrowser(urls);
  }

  Future<void> _openBrowser(List<String> urls) async {
    if (urls.isEmpty) {
      setState(() {
        _state = _DialogState.failed;
        _errorMsg = '无法打开下载链接，请重试';
      });
      return;
    }
    _browserUrls = List.unmodifiable(urls);
    _browserIndex = 0;
    await _launchBrowser(tryFollowing: true);
  }

  Future<void> _launchBrowser({bool tryFollowing = false, bool switching = false}) async {
    if (_browserOpening || _browserUrls.isEmpty) return;
    setState(() {
      _state = _DialogState.browser;
      _browserOpening = true;
      _switchingBrowserSource = switching;
      _browserMessage = '正在打开浏览器…';
    });
    var nextIndex = _browserIndex;
    final opened = await xbOpenUpdateDownload(
      _info,
      orderedUrls: tryFollowing
          ? _browserUrls.sublist(_browserIndex)
          : [_browserUrls[_browserIndex]],
      open: (uri) async {
        if (!mounted) return false;
        setState(() => _browserIndex = nextIndex++);
        return launchUrl(uri, mode: LaunchMode.externalApplication);
      },
    );
    if (!mounted) return;
    setState(() {
      _browserOpening = false;
      _browserMessage = opened
          ? '已交给浏览器；若下载失败，可换一条线路'
          : '未能打开浏览器，可重试或换线路';
    });
  }

  Future<void> _nextBrowserSource() async {
    if (_busy || _browserUrls.length < 2) return;
    _browserIndex = (_browserIndex + 1) % _browserUrls.length;
    await _launchBrowser(switching: true);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(xboardConnectivityProvider, (_, next) {
      if (!_transferActive || _interrupted != null) return;
      final links = next.asData?.value;
      if (!next.hasValue) return; // No new interface report yet.
      if (!_offline(links) && !(_needsDataConsent(links) && !_mobileAllowed)) {
        if (!_needsDataConsent(links)) _mobileAllowed = false;
        return;
      }
      final reason = _offline(links) ? '网络已断开'
          : (links?.contains(ConnectivityResult.mobile) ?? false) ? '已切换到蜂窝网络' : '网络类型已变化';
      setState(() => _interrupted = '$reason，下载已中断。请确认网络后重试，将从头下载。');
      _regionLookup?.cancel();
      _sourceProbe?.cancel();
      _cancelToken?.cancel(reason);
    });
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    // 下载中禁止「点外部 / 返回键」关闭弹窗（否则误触会触发 dispose→cancelToken.cancel 取消下载）。
    // barrier-tap 走 Navigator.maybePop（受 PopScope 约束），按钮用的直接 Navigator.pop 不受影响。
    // 初始/失败态 canPop=true，非强制更新仍可点外部「稍后再说」。
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        backgroundColor: t.sf2,
        constraints: const BoxConstraints(maxWidth: 300),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        titlePadding: const EdgeInsets.fromLTRB(22, 28, 22, 0),
        contentPadding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
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
        content: _state == _DialogState.browser ||
                _state == _DialogState.mobileConsent ||
                _state == _DialogState.selecting ||
                _state == _DialogState.downloading ||
                _state == _DialogState.handedOff ||
                (_state == _DialogState.initial && _info.force)
            ? SingleChildScrollView(child: _buildContent(t, scheme))
            : _buildContent(t, scheme),
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
        const SizedBox(height: 16),
        // Browser controls grow with text scaling; preserve existing states.
        if (_state == _DialogState.browser)
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 118),
              child: _buildFooter(t, scheme))
        else
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 84), child: Center(child: _buildFooter(t, scheme))),
      ],
    );
  }

  /// 原有状态底部高72；浏览器状态按文字与按钮内容自适应。
  Widget _buildFooter(XbTokens t, ColorScheme scheme) {
    switch (_state) {
      case _DialogState.mobileConsent:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('当前网络可能使用蜂窝流量，是否继续下载安装包？', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          XbGradientAction(onPressed: () => _onUpdate(allowMobile: true),
              child: const Text('使用蜂窝网络下载')),
          TextButton(onPressed: () => setState(() => _state = _DialogState.initial),
              child: const Text('暂不下载')),
        ]);
      case _DialogState.initial:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _initialButtons(t),
            if (_info.force)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  '此为重要更新，必须更新后使用',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: XbTokens.warn,
                  ),
                ),
              ),
          ],
        );
      case _DialogState.selecting:
      case _DialogState.downloading:
        return _downloadingFooter(scheme);
      case _DialogState.handedOff:
        return Text('下载完成，已交给安装程序', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant));
      case _DialogState.browser:
        return _browserFooter(scheme);
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

  Widget _browserFooter(ColorScheme scheme) {
    final host = Uri.parse(_browserUrls[_browserIndex]).host;
    const padding = EdgeInsets.symmetric(horizontal: 8, vertical: 12);
    const labelStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('线路 ${_browserIndex + 1}/${_browserUrls.length} · $host',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurface)),
        const SizedBox(height: 4),
        Text(_browserMessage ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 46), child: FilledButton(
            style: FilledButton.styleFrom(padding: padding, backgroundColor: XbTokens.of(context).sfc, foregroundColor: XbTokens.of(context).on),
            onPressed: _busy ? null : _launchBrowser,
            child: Text(_browserOpening && !_switchingBrowserSource ? '正在打开…' : '重新打开',
                textAlign: TextAlign.center, style: labelStyle),
          ))),
          const SizedBox(width: 11),
          Expanded(child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 46), child: XbGradientAction(
            padding: padding,
            busyLabel: _browserOpening && _switchingBrowserSource ? '正在切换线路…' : null,
            onPressed: _busy || _browserUrls.length < 2 ? null : _nextBrowserSource,
            child: const Text('换下一条', textAlign: TextAlign.center, style: labelStyle),
          ))),
        ]),
      ],
    );
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
            child: XbGradientAction(
              onPressed: _onUpdate,
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
            child: XbGradientAction(
              onPressed: _onUpdate,
              child: const Text('重试'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _downloadingFooter(ColorScheme scheme) {
    if (_transferActive && _interrupted != null) {
      return Text(_interrupted!, textAlign: TextAlign.center);
    }
    if (_state == _DialogState.selecting || _totalBytes <= 0) {
      final transferring = _state == _DialogState.downloading && _receivedBytes > 0;
      final String status;
      if (_state == _DialogState.selecting) {
        status = '选择线路中…';
      } else if (transferring) {
        final bytes = _receivedBytes;
        final size = switch (bytes) {
          < 1024 => '$bytes B',
          < 1048576 => '${(bytes / 1024).toStringAsFixed(1)} KiB',
          _ => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
        };
        status = '正在下载 · 已接收 $size（总大小未知）';
      } else {
        status = '正在准备下载…';
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: scheme.primary,
              backgroundColor: scheme.primary.withValues(alpha: 0.2),
            ),
          ),
          const SizedBox(height: 18), // 10px flex gap + 8px status margin
          Text(
            status,
            maxLines: transferring ? null : 1,
            overflow: transferring ? TextOverflow.visible : TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    // 原型 15f2：胶囊进度条(品牌红填充 + 内嵌白字百分比) + 下方「正在下载 · 已下载/总大小」
    final progress = (_receivedBytes / _totalBytes).clamp(0.0, 1.0);
    final pct = (progress * 100).toInt();
    final receivedMb = (_receivedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = (_totalBytes / (1024 * 1024)).toStringAsFixed(1);
    final brand = scheme.primary;
    final highlight = brand == const Color(0xffd92e1a)
        ? const Color(0xffff5a44)
        : Color.lerp(brand, Colors.white, 0.16)!;
    final radius = BorderRadius.circular(18);
    const labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 未覆盖部分采用主题正文色；白字只在彩色填充上绘制。语义只读一次。
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 36),
          decoration: BoxDecoration(
            color: brand.withValues(alpha: 0.08),
            border: Border.all(color: brand.withValues(alpha: 0.12)),
            borderRadius: radius,
          ),
          child: Semantics(
            value: '$pct%',
            label: '下载进度',
            excludeSemantics: true,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [brand, highlight],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('$pct%', style: labelStyle.copyWith(color: scheme.onSurface)),
                ),
                Positioned.fill(
                  child: ClipRRect(
                    clipper: _ProgressClipper(progress),
                    child: Center(
                      child: Text(
                        '$pct%',
                        style: labelStyle.copyWith(
                          color: Colors.white,
                          shadows: const [Shadow(color: Color(0x4d000000), blurRadius: 4)],
                        ),
                      ),
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
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 从左裁剪百分比白字；其余字符露出底层主题文字。
class _ProgressClipper extends CustomClipper<RRect> {
  _ProgressClipper(this.progress);
  final double progress;

  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, size.width * progress, size.height),
    const Radius.circular(18),
  ).scaleRadii();

  @override
  bool shouldReclip(_ProgressClipper old) => old.progress != progress;
}
