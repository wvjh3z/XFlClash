/// 更新弹窗组件（原型 #15d/15e/15f，参考退出登录 xbConfirm 风格）。
///
/// - 正常更新：两个并排按钮（灰底"以后再说" + 品牌色"立即更新"）
/// - 强制更新：只有品牌色"立即更新"，不可关闭
/// - 点「立即更新」→ 探活多源 → 浏览器打开（档1）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show AppUpdateModel;
import 'package:url_launcher/url_launcher.dart';

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

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final AppUpdateModel info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;

  Future<void> _onUpdate() async {
    setState(() => _downloading = true);
    final url = await _findReachableUrl();
    if (url == null) {
      if (mounted) setState(() => _downloading = false);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (mounted) setState(() => _downloading = false);
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (mounted) setState(() => _downloading = false);
  }

  Future<String?> _findReachableUrl() async {
    final downloads = widget.info.downloads;
    if (downloads.isEmpty) return null;

    // 按 region 优先排序
    final sorted = [...downloads];
    sorted.sort((a, b) {
      final aMatch = a.region == widget.info.region ? 0 : 1;
      final bMatch = b.region == widget.info.region ? 0 : 1;
      return aMatch.compareTo(bMatch);
    });

    // 依次 HEAD 探活（超时 5s）
    for (final dl in sorted) {
      final uri = Uri.tryParse(dl.url);
      if (uri == null) continue;
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);
        final request = await client.headUrl(uri);
        final response =
            await request.close().timeout(const Duration(seconds: 5));
        client.close(force: true);
        if (response.statusCode >= 200 && response.statusCode < 400) {
          return dl.url;
        }
      } catch (_) {
        // 该源不可达，试下一个
      }
    }
    // 全部探活失败 → 兜底用最后一个
    return sorted.last.url;
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '🎉 发现新版本',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.info.versionName} 可用',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Changelog
          if (widget.info.changelog.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxHeight: 140),
              decoration: BoxDecoration(
                color: t.sf,
                borderRadius: BorderRadius.circular(XbTokens.rSm),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.info.changelog,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 2,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          // 强制更新提示
          if (widget.info.force)
            Padding(
              padding: const EdgeInsets.only(top: 10),
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
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: [
        if (_downloading)
          // 下载中：不可关闭，只显示进度提示
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton(
              onPressed: null,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(XbTokens.rMd)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white)),
                  SizedBox(width: 8),
                  Text('正在打开下载…'),
                ],
              ),
            ),
          )
        else
          Row(
            children: [
              // "以后再说"按钮（非强制时显示）
              if (!widget.info.force)
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
                            borderRadius:
                                BorderRadius.circular(XbTokens.rMd)),
                      ),
                      child: const Text('以后再说'),
                    ),
                  ),
                ),
              if (!widget.info.force) const SizedBox(width: 11),
              // "立即更新"按钮
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: FilledButton(
                    onPressed: _onUpdate,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(XbTokens.rMd)),
                    ),
                    child: const Text('立即更新'),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
