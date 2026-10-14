/// 使用教程列表页（form-a · 原型「使用教程」屏）。
///
/// 从「我的」Tab → 账户组「使用教程」push 进入（**需登录**，入口仅登录态可点）。
/// 加载后端知识库，仅「官方客户端」分类（过滤在反腐层做）。点条目 push 教程详情。
///
/// 加载时仅显示目录骨架；成功显示后台标题及更新时间，不加分类标题。
/// 未返回目标分类与该分类无文章统一显示可刷新的空态；失败、超时与登录失效分别展示。
/// 正常目录、空态、失败与超时均支持下拉刷新，与显式按钮共用同一刷新入口。
///
/// **数据**：`tutorialsProvider`（autoDispose），成功值与 AsyncError 按明确状态分流。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_domain_error.dart';
import '../models/xb_tutorial.dart';
import '../providers/auth_state_provider.dart';
import '../providers/tutorial_provider.dart';
import '../util/format.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush, XbTokens;
import '../widgets/xb_ui_kit.dart'
    show XbBrandScaffold, XbIconBadge, XbPrimaryButton;
import 'tutorial_detail_page.dart';

class TutorialListPage extends ConsumerWidget {
  const TutorialListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authenticated =
        ref.watch(authStateProvider) == AuthState.authenticated;
    return XbBrandScaffold(
      title: '使用教程',
      body: authenticated
          ? const _TutorialListBody()
          : const XbEmptyState(
              icon: Icons.lock_outline,
              title: '请先登录',
              description: '登录后查看使用教程。',
            ),
    );
  }
}

class _TutorialListBody extends ConsumerWidget {
  const _TutorialListBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tutorialsProvider);
    if (async.isLoading) {
      return const XbSkeletonView(kind: XbSkeletonKind.list);
    }
    return RefreshIndicator(
      onRefresh: () => _reload(ref),
      child: async.hasError
          ? _error(async.error, () => _reload(ref))
          : _content(context, async.requireValue, () => _reload(ref)),
    );
  }

  /// 按钮与下拉共用；失效后立即读取 future 开始新请求，随后连点只会看到 loading。
  Future<void> _reload(WidgetRef ref) async {
    if (ref.read(tutorialsProvider).isLoading) return;
    ref.invalidate(tutorialsProvider);
    try {
      await ref.read(tutorialsProvider.future);
    } catch (_) {
      // provider 保留失败供下一帧展示，不让 RefreshIndicator 的 future 泄漏异常。
    }
  }

  Widget _error(Object? error, VoidCallback onRetry) {
    if (error is XbUnauthorized) {
      return const _TutorialListStatus(
        icon: Icons.lock_outline,
        title: '登录已过期，请重新登录',
        description: '登录后查看使用教程。',
      );
    }
    final timedOut = error is XbNetwork && error.kind == XbNetworkKind.timeout;
    return _TutorialListStatus(
      icon: Icons.cloud_off_outlined,
      failed: true,
      title: timedOut ? '加载超时' : '教程加载失败',
      description: timedOut ? '等待时间较长，请重试。' : '暂时无法加载，请稍后重试。',
      actionLabel: '重试',
      onAction: onRetry,
    );
  }

  Widget _content(
    BuildContext context,
    List<XbTutorial> tutorials,
    VoidCallback onRefresh,
  ) {
    if (tutorials.isEmpty) {
      return _TutorialListStatus(
        icon: Icons.menu_book_outlined,
        title: '暂无使用教程',
        description: '教程正在准备中，请稍后再来看看。',
        actionLabel: '刷新',
        onAction: onRefresh,
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        // 桌面宽窗下内容居中并收到手机级宽度（与分享好友页一致）；手机本就窄，无影响。
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                XbCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < tutorials.length; i++) ...[
                        if (i != 0)
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: XbTokens.of(context).hair,
                          ),
                        _TutorialRow(tutorial: tutorials[i]),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 不嵌套滚动容器，保证短页面也可下拉；内容较高时由同一 scroll view 正常滚动。
class _TutorialListStatus extends StatelessWidget {
  const _TutorialListStatus({
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
    this.failed = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(XbTokens.s6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    XbIconBadge(
                      icon: icon,
                      size: 80,
                      radius: XbTokens.rLg,
                      background: failed
                          ? XbTokens.bad.withValues(alpha: 0.09)
                          : t.sfc,
                      iconColor: failed ? XbTokens.bad : t.onv,
                      iconSize: 36,
                    ),
                    const SizedBox(height: XbTokens.s4),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: t.on,
                      ),
                    ),
                    const SizedBox(height: XbTokens.s2),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.onv, height: 1.6),
                    ),
                    if (actionLabel != null) ...[
                      const SizedBox(height: XbTokens.s5),
                      SizedBox(
                        width: 160,
                        child: XbPrimaryButton(
                          label: actionLabel!,
                          icon: Icons.refresh,
                          onPressed: onAction,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
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
                  Text(
                    tutorial.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: t.on,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '更新于 ${xbDate(tutorial.updatedAt)}',
                    style: TextStyle(fontSize: 11.5, color: t.onv),
                  ),
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
