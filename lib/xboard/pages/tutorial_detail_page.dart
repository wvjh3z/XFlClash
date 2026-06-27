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
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_tutorial.dart';
import '../providers/tutorial_provider.dart';
import '../providers/xboard_providers.dart' show apiEndpointProvider;
import '../services/xboard_release_dio.dart';
import '../util/format.dart';
import '../util/html_link.dart';
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
        builder: (context) => _content(context, ref, async.requireValue),
      ),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, XbTutorialDetail d) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    // 相对链接（downloads/x.apk、/#/dashboard）的解析基准 = 当前站点根（API endpoint）。
    final linkBase = ref.read(apiEndpointProvider);
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
                  data: wrapEmojiForHtml(htmlRenderableBody(d.body)),
                  // <img> 自定义渲染：走直连放行 dio 拉字节（绕过全局 FlClashHttpOverrides，
                  // 否则默认 Image.network 在未连接/内核未就绪时加载失败）。
                  extensions: [
                    TagExtension(
                      tagsToExtend: const {'img'},
                      builder: (ctx) =>
                          _TutorialImage(ctx.attributes['src'] ?? ''),
                    ),
                    // 「复制」按钮（apple-card 共享账号）：可见 .value 是脱敏的，完整值藏在
                    // data-original-onclick="copy('完整值')"（后端约定）。flutter_html 无 JS，
                    // 默认 <button> 点了没反应 → 用扩展取出完整值做成真能复制的按钮。
                    TagExtension(
                      tagsToExtend: const {'button'},
                      builder: (ctx) {
                        final raw =
                            ctx.attributes['data-original-onclick'] ?? '';
                        final m = RegExp(r"""copy\(\s*['"]([^'"]*)['"]\s*\)""")
                            .firstMatch(raw);
                        final label = (ctx.element?.text ?? '').trim();
                        return _CopyButton(
                            value: m?.group(1) ?? '',
                            label: label.isEmpty ? '复制' : label);
                      },
                    ),
                  ],
                  style: {
                    'body': Style(
                      margin: Margins.zero,
                      padding: HtmlPaddings.zero,
                      fontSize: FontSize(15),
                      lineHeight: LineHeight.number(1.75),
                      color: t.on,
                    ),
                    // emoji-only：仅 emoji span 套 Twemoji（含国旗，跨端一致）。不能用 body
                    // fontFamilyFallback:[Twemoji]——Twemoji 含数字字形会吃掉正文数字（COLR 基字
                    // 不可见，详见 wrapEmojiForHtml）。
                    '.$kXbEmojiClass': Style(fontFamily: 'Twemoji'),
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
                    // apple-card 内部结构（共享账号卡）：后端用这些 class 做卡片排版，
                    // 补 Style 让账号/密码行成形（flutter_html 无 flex，label/value/按钮纵向堆叠）。
                    '.header': Style(
                      fontWeight: FontWeight.w700,
                      fontSize: FontSize(15),
                      margin: Margins.only(bottom: 8),
                    ),
                    '.row': Style(
                      padding: HtmlPaddings.symmetric(vertical: 8),
                      border: Border(top: BorderSide(color: t.hair)),
                    ),
                    '.label': Style(color: t.onv, fontSize: FontSize(12.5)),
                    '.value': Style(
                      color: t.on,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                    '.status-ok':
                        Style(color: const Color(0xFF16A34A), fontSize: FontSize(13)),
                  },
                  onLinkTap: (url, _, _) =>
                      openHtmlLink(url, base: linkBase), // 统一链接框架（含相对链接解析）。
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// apple-card 共享账号「复制」按钮：复制完整值（取自 data-original-onclick）到剪贴板。
///
/// 可见 `.value` 是脱敏的；完整值在按钮的 `data-original-onclick="copy('完整值')"` 属性里
/// （后端约定）。flutter_html 不执行 JS，故用本 widget 取出真值做可点复制。
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: OutlinedButton.icon(
        // 无完整值（非 copy 按钮）→ 禁用，仅显示文字。
        onPressed: value.isEmpty
            ? null
            : () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('已复制'),
                      duration: Duration(milliseconds: 1200)),
                );
              },
        icon: const Icon(Icons.copy_rounded, size: 15),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          minimumSize: const Size(0, 34),
        ),
      ),
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
