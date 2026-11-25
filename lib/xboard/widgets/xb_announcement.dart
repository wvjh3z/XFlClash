/// 公告 UI（form-a 首页）：标题旁「有新公告」胶囊 + 点击弹出公告 sheet。
///
/// - 胶囊（[XbNoticePill]）：watch [noticeStateProvider]，仅 `hasUnread` 时显示（纯文字，无红点）。
/// - 点击：**打开即已读**（用户决策）—— 本地标记已读（徽标消失，不重新请求正文）→ 弹 sheet。
/// - sheet 正文用 flutter_html 渲染（复用 §6.5 框架：emoji 分流 / 正文清洗 / 主题色 / 链接），
///   HTML 和 Markdown 共用正文样式与链接处理。
library;

import 'package:fl_clash/xboard/widgets/xb_emoji_text.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_notice.dart';
import '../providers/notice_provider.dart';
import '../providers/auth_state_provider.dart';
import '../providers/xboard_providers.dart';
import '../shell/sheets/sheet_scaffold.dart';
import '../util/format.dart' show xbDate;
import '../util/html_link.dart';
import '../util/html_text.dart' show wrapEmojiForHtml, kXbEmojiClass;
import '../util/notice_html.dart';
import 'xb_ui_kit.dart' show XbGradientAction;
import 'xb_network_read_recovery.dart';
import 'xb_html_contrast.dart' show xbReadableHtmlColor;
import 'xb_theme.dart' show XbTokens;

// Acknowledge only the exact snapshot that the user opened. A later server
// response computes unread status from its own notice versions and owner.
final _openedSnapshot = NotifierProvider.autoDispose<_OpenedSnapshot, XbNoticeState?>(_OpenedSnapshot.new);
class _OpenedSnapshot extends Notifier<XbNoticeState?> {
  @override
  XbNoticeState? build() => null;
  void acknowledge(XbNoticeState notice) => state = notice;
}

/// 「有新公告」胶囊（标题旁）。无未读 / 游客 / 未就绪 → 不占位。
/// 桌面 [large]=true：字号 13 + 更大内距（与 `_HomeUpdatePill` 桌面态一致）。
class XbNoticePill extends ConsumerStatefulWidget {
  const XbNoticePill({super.key, this.large = false});

  final bool large;

  @override
  ConsumerState<XbNoticePill> createState() => _XbNoticePillState();
}

class _XbNoticePillState extends ConsumerState<XbNoticePill> {
  bool _opening = false;
  bool _visible = false;
  final _age = Stopwatch()..start();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refreshIfStale);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled && ModalRoute.of(context)?.isCurrent != false;
    if (visible && !_visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshIfStale());
    }
    _visible = visible;
  }

  void _refreshIfStale() {
    if (!mounted || !_visible || _opening || _age.elapsed < const Duration(minutes: 1)) return;
    final current = ref.read(noticeStateProvider);
    if (!current.isLoading && !current.hasError) {
      _age.reset();
      ref.invalidate(noticeStateProvider);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _open(XbNoticeState notice) async {
    if (!mounted || _opening) return;
    _opening = true;
    try {
      await ref.read(noticeReadStoreProvider).markRead(
        notice.notices, userIdHash: notice.userIdHash,
      );
      if (!mounted) return;
      ref.read(_openedSnapshot.notifier).acknowledge(notice);
      await showXbNoticeSheet(context, notice.notices);
    } finally {
      // No setState: disposal also safely releases this instance's guard.
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(noticeStateProvider);
    ref.listen(noticeStateProvider, (_, next) {
      if (!next.isLoading) _age.reset();
    });
    xbListenForPendingReadRecovery(context, ref,
      state: () => ref.read(noticeStateProvider),
      future: () => ref.read(noticeStateProvider.future),
      current: () => _visible && ref.read(authStateProvider) == AuthState.authenticated,
      retry: () => ref.invalidate(noticeStateProvider),
    );
    final s = result.asData?.value;
    final opened = ref.watch(_openedSnapshot);
    if (result.hasError || s == null || !s.hasUnread || identical(s, opened)) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _open(s),
      child: Container(
        padding: widget.large
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 7)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.22)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.campaign_outlined,
                size: widget.large ? 16 : 14, color: scheme.primary),
            const SizedBox(width: 4),
            Text('有新公告',
                style: TextStyle(
                    fontSize: widget.large ? 13 : 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary)),
          ],
        ),
      ),
    );
  }
}

/// 公告弹窗（底部 sheet）：标题「公告」+ 公告列表（标题↔日期 + 富文本正文）+「我知道了」。
Future<void> showXbNoticeSheet(BuildContext context, List<XbNotice> notices) {
  return showXbBottomSheet<void>(
    context: context,
    builder: (ctx) {
      final t = XbTokens.of(ctx);
      final brand = Theme.of(ctx).colorScheme.primary;
      final quoteBg = Color.alphaBlend(brand.withValues(alpha: .05), t.sf2);
      final linkInk = xbReadableHtmlColor(xbReadableHtmlColor(brand, t.sf2), quoteBg);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Text('公告',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: t.on)),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < notices.length; i++) ...[
                        if (i > 0) Divider(height: 1, color: t.hair),
                        _NoticeItem(notice: notices[i], quoteBg: quoteBg, linkInk: linkInk),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: XbGradientAction(
                  height: 50,
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('我知道了'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 单条公告：标题行(标题 ←→ 日期) + flutter_html 富文本正文（复用 §6.5 框架）。
class _NoticeItem extends ConsumerWidget {
  const _NoticeItem({required this.notice, required this.quoteBg, required this.linkInk});

  final XbNotice notice;
  final Color quoteBg;
  final Color linkInk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: XbEmojiText(notice.title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: t.on)),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(xbDate(notice.createdAt),
                    style: TextStyle(fontSize: 11, color: t.onv)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 正文：emoji 分流 + 正文清洗（§6.5）；链接走统一框架（base=当前 API endpoint）。
          Html(
            data: wrapEmojiForHtml(noticeRenderableHtml(notice.content)),
            style: {
              'body': Style(
                  margin: Margins.zero,
                  padding: HtmlPaddings.zero,
                  fontSize: FontSize(13),
                  lineHeight: const LineHeight(1.65),
                  color: t.on),
              'h4': Style(fontSize: FontSize(13.5), fontWeight: FontWeight.w700,
                  margin: Margins.only(top: 10, bottom: 4)),
              'p': Style(margin: Margins.symmetric(vertical: 6)),
              'ul': Style(margin: Margins.symmetric(vertical: 6),
                  padding: HtmlPaddings.only(left: 20)),
              'li': Style(margin: Margins.symmetric(vertical: 2)),
              'strong': Style(fontWeight: FontWeight.w700),
              'a': Style(color: linkInk, textDecoration: TextDecoration.none),
              'blockquote': Style(display: Display.block, color: t.onv),
              'code': Style(fontFamily: 'monospace', fontSize: FontSize(12)),
              '.$kXbEmojiClass': Style(fontFamily: 'Twemoji'),
            },
            // flutter_html 3.0.0 的普通 inline TextSpan 不绘制内边距/圆角；
            // 沿用解析后的子 spans，保留内嵌链接、强调和 emoji。
            extensions: [
              TagExtension.inline(
                tagsToExtend: const {'code', 'blockquote'},
                builder: (ctx) {
                  final code = ctx.elementName == 'code';
                  final content = Text.rich(TextSpan(
                    style: ctx.style!.generateTextStyle(),
                    children: ctx.inlineSpanChildren!,
                  ));
                  return WidgetSpan(
                    alignment: code ? PlaceholderAlignment.baseline : PlaceholderAlignment.bottom,
                    baseline: TextBaseline.alphabetic,
                    child: code
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(color: t.sfc, borderRadius: BorderRadius.circular(5)),
                            child: content,
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: ClipRRect(
                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                                decoration: BoxDecoration(
                                  color: quoteBg,
                                  border: Border(left: BorderSide(width: 3, color: Color.lerp(brand, t.line, .5)!)),
                                ),
                                child: content,
                              ),
                            ),
                          ),
                  );
                },
              ),
            ],
            onLinkTap: (url, _, _) =>
                openHtmlLink(url, base: ref.read(apiEndpointProvider)),
          ),
        ],
      ),
    );
  }
}
