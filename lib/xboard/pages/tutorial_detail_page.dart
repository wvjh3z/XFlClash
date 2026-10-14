/// Authenticated tutorial reader. Article headings belong to the HTML itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_state_provider.dart';
import '../providers/tutorial_provider.dart';
import '../providers/xboard_providers.dart';
import '../util/tutorial_html.dart';
import '../util/tutorial_resource_base.dart';
import '../widgets/tutorial_webview.dart';
import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush;
import '../widgets/xb_ui_kit.dart' show XbBrandScaffold;

class TutorialReaderContent {
  const TutorialReaderContent({
    required this.html,
    required this.resourceBase,
    required this.openTutorial,
    required this.articleId,
  });
  final String html;
  final Uri resourceBase;
  final Future<void> Function(int id) openTutorial;
  final int articleId;
}

typedef TutorialReaderBuilder =
    Widget Function(BuildContext context, TutorialReaderContent content);

/// Native views are replaceable for page-state tests, without faking DOM tests.
final tutorialReaderBuilderProvider = Provider<TutorialReaderBuilder>(
  (ref) =>
      (context, content) => TutorialWebView(
        html: content.html,
        resourceBase: content.resourceBase,
        onOpenTutorial: content.openTutorial,
        articleUrl: content.resourceBase.replace(
          fragment: '/docs/${content.articleId}',
        ),
      ),
);

class TutorialDetailPage extends ConsumerWidget {
  const TutorialDetailPage({super.key, required this.id});
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authenticated =
        ref.watch(authStateProvider) == AuthState.authenticated;
    return XbBrandScaffold(
      title: '教程详情',
      maxContentWidth: 960,
      actions: [
        if (authenticated)
          IconButton(
            tooltip: '刷新教程',
            icon: const Icon(Icons.refresh),
            onPressed: ref.watch(tutorialDetailProvider(id)).isLoading
                ? null
                : () => ref.invalidate(tutorialDetailProvider(id)),
          ),
      ],
      // Do not animate the old native document into the guest state.
      body: authenticated
          ? _DetailBody(
              key: ValueKey((
                id,
                ref.read(authStateProvider.notifier).sessionRevision,
              )),
              id: id,
            )
          : const XbEmptyState(
              icon: Icons.lock_outline,
              title: '请先登录',
              description: '登录后查看使用教程。',
            ),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({super.key, required this.id});
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tutorialDetailProvider(id));
    return XbAsyncView(
      loading: async.isLoading,
      error: async.hasError ? async.error : null,
      errorFallback: '加载教程失败',
      onRetry: () => ref.invalidate(tutorialDetailProvider(id)),
      builder: (context) {
        final detail = async.requireValue;
        if (detail.body.trim().isEmpty) {
          return const XbEmptyState(
            icon: Icons.menu_book_outlined,
            title: '教程暂无内容',
            description: '请稍后刷新重试。',
          );
        }
        final resourceBase =
            tutorialResourceBase(detail.resourceBase) ??
            tutorialResourceBase(ref.read(apiEndpointProvider)) ??
            Uri.parse('https://invalid.example/');
        final revision = ref.read(authStateProvider.notifier).sessionRevision;
        final content = TutorialReaderContent(
          articleId: id,
          html: buildTutorialHtml(
            detail.body,
            resourceBase: resourceBase,
            isDark: Theme.of(context).brightness == Brightness.dark,
          ),
          resourceBase: resourceBase,
          openTutorial: (nextId) async {
            if (!context.mounted ||
                ref.read(authStateProvider) != AuthState.authenticated ||
                ref.read(authStateProvider.notifier).sessionRevision !=
                    revision) {
              return;
            }
            await xbPush(
              context,
              TutorialDetailPage(id: nextId),
              brandColor: xbBrandColor(),
            );
          },
        );
        return KeyedSubtree(
          key: ValueKey((
            id,
            revision,
            identityHashCode(detail),
            Theme.of(context).brightness,
          )),
          child: ref.watch(tutorialReaderBuilderProvider)(context, content),
        );
      },
    );
  }
}
