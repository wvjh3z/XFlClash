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

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_domain_error.dart';
import '../models/xb_tutorial.dart';
import '../providers/auth_state_provider.dart';
import '../providers/tutorial_provider.dart';
import '../providers/catalog_read_cache.dart';
import '../util/format.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_network_read_recovery.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush, XbTokens;
import '../widgets/xb_ui_kit.dart'
    show XbBrandScaffold, XbGradientAction, XbIconBadge;
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
          ? _TutorialListBody(key: ValueKey(ref.read(authStateProvider.notifier).sessionRevision))
          : const XbEmptyState(
              icon: Icons.lock_outline,
              title: '请先登录',
              description: '登录后查看使用教程。',
            ),
    );
  }
}

class _TutorialListBody extends ConsumerStatefulWidget {
  const _TutorialListBody({super.key});
  @override
  ConsumerState<_TutorialListBody> createState() => _TutorialListBodyState();
}

class _TutorialListBodyState extends ConsumerState<_TutorialListBody> {
  List<XbTutorial>? _last;
  AsyncValue<List<XbTutorial>>? _buttonSource;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () {
      if (!mounted || ref.read(catalogReadCacheProvider).fresh(('tutorials', ref.read(authStateProvider.notifier).sessionRevision)) ||
          !TickerMode.valuesOf(context).enabled || ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final current = ref.read(tutorialsProvider);
      if (!current.isLoading && !current.hasError && current.hasValue) _reload(ref);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tutorialsProvider);
    xbListenForPendingReadRecovery(context, ref,
      state: () => ref.read(tutorialsProvider),
      future: () => ref.read(tutorialsProvider.future),
      retry: () => _reload(ref),
    );
    if (async is AsyncData<List<XbTutorial>>) _last = async.value;
    if (async.hasError && !xbIsRecoverableReadError(async.error)) _last = null;
    final saved = _last;
    final buttonSource = _buttonSource;
    if (async.isLoading && buttonSource == null && (saved == null || saved.isEmpty)) {
      return const XbSkeletonView(kind: XbSkeletonKind.list);
    }
    return RefreshIndicator(
      onRefresh: () => _reload(ref),
      child: async.isLoading && buttonSource != null
          ? buttonSource.hasError
              ? _error(buttonSource.error, () {}, busy: true)
              : _content(context, const [], () {}, busy: true)
          : saved != null && saved.isNotEmpty
          ? Column(children: [
              if (async.hasError && !async.isLoading)
                TextButton(onPressed: () => _reload(ref), child: const Text('刷新失败，显示上次目录 · 重试')),
              Expanded(child: _content(context, saved, () => _reload(ref))),
            ])
          : async.hasError
          ? _error(async.error, () => _reload(ref, button: true))
          : _content(context, async.requireValue, () => _reload(ref, button: true)),
    );
  }

  /// 按钮与下拉共用；失效后立即读取 future 开始新请求，随后连点只会看到 loading。
  Future<void> _reload(WidgetRef ref, {bool button = false}) async {
    final source = ref.read(tutorialsProvider);
    if (source.isLoading || _buttonSource != null) return;
    if (button) setState(() => _buttonSource = source);
    ref.invalidate(tutorialsProvider);
    try {
      await ref.read(tutorialsProvider.future);
    } catch (_) {
      // provider 保留失败供下一帧展示，不让 RefreshIndicator 的 future 泄漏异常。
    } finally {
      if (button && mounted) setState(() => _buttonSource = null);
    }
  }

  Widget _error(Object? error, VoidCallback onRetry, {bool busy = false}) {
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
      busyLabel: busy ? '正在重新加载…' : null,
      onAction: onRetry,
    );
  }

  Widget _content(
    BuildContext context,
    List<XbTutorial> tutorials,
    VoidCallback onRefresh, {bool busy = false}
  ) {
    if (tutorials.isEmpty) {
      return _TutorialListStatus(
        icon: Icons.menu_book_outlined,
        title: '暂无使用教程',
        description: '教程正在准备中，请稍后再来看看。',
        actionLabel: '刷新',
        busyLabel: busy ? '正在刷新…' : null,
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
                            indent: MediaQuery.sizeOf(context).width < 600 ? 48 : 0,
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
    this.busyLabel,
    this.onAction,
    this.failed = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final String? busyLabel;
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
                      size: 72,
                      radius: XbTokens.rLg,
                      background: failed
                          ? Color.alphaBlend(XbTokens.bad.withValues(alpha: 0.08), t.sfc)
                          : t.sfc,
                      iconColor: failed ? XbTokens.bad : t.onv,
                      iconSize: 32,
                    ),
                    const SizedBox(height: 22),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: t.on,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 290),
                      child: Text(
                        description,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: t.onv, fontSize: 13, height: 1.75),
                      ),
                    ),
                    if (actionLabel != null) ...[
                      const SizedBox(height: 28),
                      SizedBox(
                        width: 144,
                        child: XbGradientAction(
                          onPressed: onAction,
                          busyLabel: busyLabel,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.refresh, size: 19),
                              const SizedBox(width: 7),
                              Flexible(
                                child: Text(
                                  actionLabel!,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
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
    final compact = MediaQuery.sizeOf(context).width < 600;
    return InkWell(
      onTap: () => xbPush(
        context,
        TutorialDetailPage(id: tutorial.id),
        brandColor: xbBrandColor(),
      ),
      borderRadius: BorderRadius.circular(XbTokens.rSm),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 9 : 11, horizontal: compact ? 4 : 0),
        child: Row(
          children: [
            XbIconBadge(
              icon: Icons.article_outlined,
              size: compact ? 32 : 38,
              radius: XbTokens.rSm,
              background: t.sfc,
              iconSize: compact ? 17 : 19,
              iconColor: compact ? t.on : t.onv,
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
                      fontSize: compact ? 14.5 : 14,
                      fontWeight: compact ? FontWeight.w400 : FontWeight.w600,
                      color: t.on,
                    ),
                  ),
                  SizedBox(height: compact ? 2 : 3),
                  Text(
                    '更新于 ${xbDate(tutorial.updatedAt)}',
                    style: TextStyle(fontSize: 11.5, color: t.onv),
                  ),
                ],
              ),
            ),
            SizedBox(width: compact ? 12 : 8),
            Icon(Icons.chevron_right, size: compact ? 18 : 20, color: t.onv),
          ],
        ),
      ),
    );
  }
}
