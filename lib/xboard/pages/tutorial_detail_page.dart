/// 教程详情页（form-a · 原型「教程详情」屏）。
///
/// 从「使用教程」列表点条目 push 进入（需登录）。渲染知识库文章正文（HTML）。
///
/// **三态**：加载中 → [XbAsyncView] 详情骨架（鱼骨图）；正常 → 标题 + 更新时间 + 正文（flutter_html
/// 渲染服务端 HTML）；失败 → 错误重试块。
///
/// **数据**：`tutorialDetailProvider(id)`（family + autoDispose）。永不抛（XbResult → AsyncError）。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_tutorial.dart';
import '../providers/tutorial_provider.dart';
import '../services/xboard_release_dio.dart';
import '../util/format.dart';
import '../util/html_text.dart';
import '../widgets/xb_async_view.dart';
import '../widgets/xb_theme.dart' show XbTokens;
import '../widgets/xb_ui_kit.dart' show XbBrandScaffold;

class TutorialDetailPage extends ConsumerWidget {
  const TutorialDetailPage({super.key, required this.id});

  /// 知识库文章 ID。
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return XbBrandScaffold(
      title: '教程详情',
      body: _DetailBody(id: id),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.id});
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tutorialDetailProvider(id));
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(tutorialDetailProvider(id));
        await ref.read(tutorialDetailProvider(id).future).catchError(
              (_) => XbTutorialDetail(
                  id: id, title: '', body: '', updatedAt: DateTime.now()),
            );
      },
      child: XbAsyncView(
        loading: async.isLoading,
        error: async.hasError ? async.error : null,
        errorFallback: '加载教程失败',
        onRetry: () => ref.invalidate(tutorialDetailProvider(id)),
        builder: (context) => _content(context, async.requireValue),
      ),
    );
  }

  Widget _content(BuildContext context, XbTutorialDetail d) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        // 桌面宽窗下内容居中并收到阅读宽度（与原型 680 阅读宽一致）；手机本就窄，无影响。
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.title,
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                      color: t.on),
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Icon(Icons.schedule, size: 14, color: t.onv),
                    const SizedBox(width: 5),
                    Text('更新于 ${xbDate(d.updatedAt)}',
                        style: TextStyle(fontSize: 12, color: t.onv)),
                  ],
                ),
                const SizedBox(height: 14),
                Divider(height: 1, thickness: 1, color: t.hair),
                const SizedBox(height: 6),
                // 服务端整页 HTML 正文：先抽出 <body> 内层并去掉 <style>/<head>/注释/模板占位
                // （flutter_html 不应用 <style> CSS，残留会被当文字显示），再用 Style map 还原观感。
                Html(
                  data: htmlRenderableBody(d.body),
                  // <img> 自定义渲染：走直连放行 dio 拉字节（绕过全局 FlClashHttpOverrides，
                  // 否则默认 Image.network 在未连接/内核未就绪时加载失败）。
                  extensions: [
                    TagExtension(
                      tagsToExtend: const {'img'},
                      builder: (ctx) =>
                          _TutorialImage(ctx.attributes['src'] ?? ''),
                    ),
                  ],
                  style: {
                    'body': Style(
                      margin: Margins.zero,
                      padding: HtmlPaddings.zero,
                      fontSize: FontSize(15),
                      lineHeight: LineHeight.number(1.75),
                      color: t.on,
                      // Twemoji 兜底：正文 emoji（含国旗）各端 OS 字体不一致，统一走打包字体。
                      fontFamilyFallback: const ['Twemoji'],
                    ),
                    'h1': Style(
                      fontSize: FontSize(21),
                      fontWeight: FontWeight.w700,
                      margin: Margins.only(top: 4, bottom: 4),
                    ),
                    'h2': Style(
                      fontSize: FontSize(17),
                      fontWeight: FontWeight.w700,
                      margin: Margins.only(top: 22, bottom: 10),
                      padding: HtmlPaddings.only(left: 10),
                      border: Border(left: BorderSide(color: brand, width: 4)),
                    ),
                    'p': Style(margin: Margins.symmetric(vertical: 8)),
                    'li': Style(margin: Margins.symmetric(vertical: 5)),
                    'a': Style(color: brand, textDecoration: TextDecoration.none),
                    '.subtitle':
                        Style(color: t.onv, fontSize: FontSize(13.5)),
                    '.hint': Style(color: t.onv, fontSize: FontSize(13)),
                    '.callout': Style(
                      backgroundColor: brand.withValues(alpha: 0.06),
                      border: Border.all(
                          color: brand.withValues(alpha: 0.22), width: 1),
                      padding: HtmlPaddings.all(12),
                      margin: Margins.symmetric(vertical: 12),
                    ),
                    'figcaption': Style(
                      color: t.onv,
                      fontSize: FontSize(12.5),
                      padding: HtmlPaddings.symmetric(vertical: 6),
                    ),
                    '.apple-card': Style(
                      backgroundColor: t.sfc,
                      border: Border.all(color: t.line, width: 1),
                      padding: HtmlPaddings.all(14),
                      margin: Margins.symmetric(vertical: 12),
                    ),
                  },
                  onLinkTap: (url, _, _) {}, // 正文内链接暂不跳转（v0.1）。
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 教程正文里的 `<img>`：走直连放行 dio 拉取字节再 `Image.memory` 渲染。
///
/// **为什么不用 Image.network**：App 装了全局 `FlClashHttpOverrides`（main.dart），默认 HttpClient
/// 受其接管 —— 会按 Clash 内核状态路由/校验，未连接或内核未就绪时图片加载失败。复用与 bootstrap /
/// 加密订阅同款的 [buildReleasedIsolatedDio]（findProxy=DIRECT + 证书放行）直连拉图，稳定可靠。
/// 字节做进程内缓存，避免 flutter_html 重建时重复请求。
class _TutorialImage extends StatefulWidget {
  const _TutorialImage(this.src);
  final String src;

  @override
  State<_TutorialImage> createState() => _TutorialImageState();
}

class _TutorialImageState extends State<_TutorialImage> {
  static final Map<String, Uint8List> _cache = {};
  static final Dio _dio =
      buildReleasedIsolatedDio(timeout: const Duration(seconds: 15));

  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    if (widget.src.isNotEmpty) _future = _load(widget.src);
  }

  Future<Uint8List> _load(String url) async {
    final cached = _cache[url];
    if (cached != null) return cached;
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = Uint8List.fromList(resp.data ?? const []);
    if (bytes.isEmpty) throw StateError('empty image');
    _cache[url] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    if (_future == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FutureBuilder<Uint8List>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return _placeholder(
                t,
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            if (snap.hasError || snap.data == null) {
              return _placeholder(
                  t, Icon(Icons.broken_image_outlined, color: t.onv));
            }
            return Image.memory(
              snap.data!,
              width: double.infinity,
              fit: BoxFit.fitWidth,
            );
          },
        ),
      ),
    );
  }

  Widget _placeholder(XbTokens t, Widget child) => Container(
        height: 160,
        decoration: BoxDecoration(
          color: t.sfc,
          border: Border.all(color: t.line),
        ),
        alignment: Alignment.center,
        child: child,
      );
}
