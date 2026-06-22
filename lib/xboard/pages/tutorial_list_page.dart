/// 使用教程列表页（form-a · 原型「使用教程」屏）。
///
/// 从「我的」Tab → 账户组「使用教程」push 进入（**需登录**，入口仅登录态可点）。
/// 加载后端知识库，仅「官方客户端」分类（过滤在反腐层做）。点条目 push 教程详情。
///
/// **三态**（原型 ok / loading / empty）：
/// - 加载中 → [XbAsyncView] 骨架（list）；
/// - 正常 → 分组标题 + 教程列表卡（每行 article 图标 + 标题 + 更新时间 + chevron）+ 说明；
/// - 空（该分类无文章）/ 拉取失败 → [XbEmptyState]。
///
/// **数据**：`tutorialsProvider`（autoDispose）。永不抛（XbResult → AsyncError 由 XbAsyncView 分流）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_tutorial.dart';
import '../providers/tutorial_provider.dart';
import '../util/format.dart';
import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush, XbTokens;
import '../widgets/xb_ui_kit.dart' show XbBrandScaffold;
import 'tutorial_detail_page.dart';

class TutorialListPage extends ConsumerWidget {
  const TutorialListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const XbBrandScaffold(
      title: '使用教程',
      body: _TutorialListBody(),
    );
  }
}

class _TutorialListBody extends ConsumerWidget {
  const _TutorialListBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tutorialsProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(tutorialsProvider);
        await ref
            .read(tutorialsProvider.future)
            .catchError((_) => const <XbTutorial>[]);
      },
      child: XbAsyncView(
        loading: async.isLoading,
        error: async.hasError ? async.error : null,
        errorFallback: '加载教程失败',
        skeleton: XbSkeletonKind.list,
        onRetry: () => ref.invalidate(tutorialsProvider),
        builder: (context) => _content(context, async.requireValue),
      ),
    );
  }

  Widget _content(BuildContext context, List<XbTutorial> tutorials) {
    if (tutorials.isEmpty) {
      return const XbEmptyState(
        icon: Icons.menu_book_outlined,
        title: '暂无使用教程',
        description: '管理员尚未发布「官方客户端」分类的教程，请稍后再试。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        // 桌面宽窗下内容居中并收到手机级宽度（与分享好友页一致）；手机本就窄，无影响。
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const XbGroupLabel('官方客户端 · 使用教程'),
                XbCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      for (var i = 0; i < tutorials.length; i++) ...[
                        if (i != 0)
                          Divider(
                              height: 1,
                              thickness: 1,
                              color: XbTokens.of(context).hair),
                        _TutorialRow(tutorial: tutorials[i]),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const XbInfoCard(
                  icon: Icons.info_outline,
                  text: '仅展示「官方客户端」分类的教程，内容由服务端知识库下发。',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 单条教程行：article 徽标 + 标题 + 更新时间 + chevron，点开 push 详情。
class _TutorialRow extends StatelessWidget {
  const _TutorialRow({required this.tutorial});
  final XbTutorial tutorial;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return InkWell(
      onTap: () => xbPush(
        context,
        TutorialDetailPage(id: tutorial.id),
        brandColor: xbBrandColor(),
      ),
      borderRadius: BorderRadius.circular(XbTokens.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.sfc,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.article_outlined, size: 19, color: t.onv),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tutorial.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: t.on)),
                  const SizedBox(height: 3),
                  Text('更新于 ${xbDate(tutorial.updatedAt)}',
                      style: TextStyle(fontSize: 11.5, color: t.onv)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: t.onv),
          ],
        ),
      ),
    );
  }
}
