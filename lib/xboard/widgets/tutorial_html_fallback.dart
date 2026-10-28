/// Linux fallback until a stable native inline WebView is selected for Linux.
library;

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';

import '../services/xboard_release_dio.dart';
import '../util/html_link.dart' show resolveHtmlLink;
import '../util/html_text.dart';
import 'xb_theme.dart' show XbTokens;

class TutorialHtmlFallback extends StatelessWidget {
  const TutorialHtmlFallback({
    super.key,
    required this.html,
    required this.resourceBase,
    required this.onOpenLink,
  });
  final String html;
  final Uri resourceBase;
  final Future<bool> Function(String raw) onOpenLink;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Html(
        data: wrapEmojiForHtml(htmlRenderableBody(html)),
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
          '.subtitle': Style(color: t.onv, fontSize: FontSize(13.5)),
          '.hint': Style(color: t.onv, fontSize: FontSize(13)),
          '.callout': Style(
            backgroundColor: brand.withValues(alpha: 0.06),
            border: Border.all(color: brand.withValues(alpha: 0.22), width: 1),
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
          '.status-ok': Style(
            color: const Color(0xFF16A34A),
            fontSize: FontSize(13),
          ),
        },
        extensions: [
          TagExtension(
            tagsToExtend: const {'img'},
            builder: (ctx) => _DirectImage(
              src: ctx.attributes['src'] ?? '',
              base: resourceBase.toString(),
            ),
          ),
          TagExtension(
            tagsToExtend: const {'button'},
            builder: (ctx) {
              final value = ctx.attributes['data-xb-copy'];
              final jump = ctx.attributes['data-xb-jump'];
              return OutlinedButton(
                onPressed: jump != null
                    ? () async {
                        await onOpenLink(jump);
                      }
                    : value == null
                    ? null
                    : () async {
                        try {
                          await Clipboard.setData(ClipboardData(text: value));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制')),
                            );
                          }
                        } catch (_) {}
                      },
                child: Text(ctx.element?.text.trim() ?? '复制'),
              );
            },
          ),
        ],
        onLinkTap: (url, _, _) {
          if (url != null) onOpenLink(url);
        },
      ),
    );
  }
}

class _DirectImage extends StatefulWidget {
  const _DirectImage({required this.src, required this.base});
  final String src;
  final String base;
  @override
  State<_DirectImage> createState() => _DirectImageState();
}

class _DirectImageState extends State<_DirectImage> {
  Dio? _dio;
  late Future<Uint8List?> _bytes;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_DirectImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src || oldWidget.base != widget.base) _load();
  }

  void _load() {
    _dio?.close(force: true);
    final uri = resolveHtmlLink(widget.src, base: widget.base);
    final dio = _dio = buildReleasedIsolatedDio(
      timeout: const Duration(seconds: 10),
    );
    _bytes = uri != null && (uri.isScheme('http') || uri.isScheme('https'))
        ? dio
              .get<List<int>>(
                uri.toString(),
                options: Options(responseType: ResponseType.bytes),
              )
              .then((r) => r.data == null ? null : Uint8List.fromList(r.data!))
        : Future.value(null);
  }

  @override
  void dispose() {
    _dio?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    builder: (context, snapshot) => snapshot.data != null
        ? Image.memory(
            snapshot.data!,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          )
        : const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.image_outlined),
          ),
  );
}
