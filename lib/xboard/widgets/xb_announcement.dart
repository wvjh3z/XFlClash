/// 公告 UI（form-a 首页）：标题旁「有新公告」胶囊 + 点击弹出公告 sheet。
///
/// - 胶囊（[XbNoticePill]）：watch [noticeStateProvider]，仅 `hasUnread` 时显示（纯文字，无红点）。
/// - 点击：**打开即已读**（用户决策）—— 标记已读 + 失效 provider（徽标消失）→ 弹 sheet。
/// - sheet 正文用 flutter_html 渲染（复用 §6.5 框架：emoji 分流 / 正文清洗 / 主题色 / 链接），
///   与套餐/教程同一条渲染管线（markdown 由后端/编辑器侧统一存 HTML，客户端只渲 HTML）。
library;

import 'package:fl_clash/widgets/widgets.dart' show EmojiText;
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_notice.dart';
import '../providers/notice_provider.dart';
import '../providers/xboard_providers.dart';
import '../shell/sheets/sheet_scaffold.dart';
import '../util/format.dart' show xbDate;
import '../util/html_link.dart';
import '../util/html_text.dart' show wrapEmojiForHtml, htmlRenderableBody, kXbEmojiClass;
import 'xb_theme.dart' show XbTokens;

/// 「有新公告」胶囊（标题旁）。无未读 / 游客 / 未就绪 → 不占位。
/// 桌面 [large]=true：字号 13 + 更大内距（与 `_HomeUpdatePill` 桌面态一致）。
class XbNoticePill extends ConsumerWidget {
  const XbNoticePill({super.key, this.large = false});

  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(noticeStateProvider).asData?.value;
    if (s == null || !s.hasUnread) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () async {
        // 打开即已读：标记当前这批 + 失效 provider（徽标消失），再弹 sheet。
        await ref
            .read(noticeReadStoreProvider)
            .markRead(s.notices, userIdHash: s.userIdHash);
        ref.invalidate(noticeStateProvider);
        if (context.mounted) showXbNoticeSheet(context, s.notices);
      },
      child: Container(
        padding: large
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
                size: large ? 16 : 14, color: scheme.primary),
            const SizedBox(width: 4),
            Text('有新公告',
                style: TextStyle(
                    fontSize: large ? 13 : 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary)),
          ],
        ),
      ),
    );
  }
}

/// 公告弹窗（底部 sheet）：标题「公告」+ 公告列表（标题↔日期 + 富文本正文）+「我知道了」。
void showXbNoticeSheet(BuildContext context, List<XbNotice> notices) {
  showXbBottomSheet<void>(
    context: context,
    builder: (ctx) {
      final t = XbTokens.of(ctx);
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
                        _NoticeItem(notice: notices[i]),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
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
  const _NoticeItem({required this.notice});

  final XbNotice notice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = XbTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: EmojiText(notice.title,
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
            data: wrapEmojiForHtml(htmlRenderableBody(notice.content)),
            style: {
              'body': Style(
                  margin: Margins.zero,
                  padding: HtmlPaddings.zero,
                  color: t.on),
              '.$kXbEmojiClass': Style(fontFamily: 'Twemoji'),
            },
            onLinkTap: (url, _, _) =>
                openHtmlLink(url, base: ref.read(apiEndpointProvider)),
          ),
        ],
      ),
    );
  }
}
