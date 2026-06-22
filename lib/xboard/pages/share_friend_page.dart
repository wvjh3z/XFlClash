/// 分享好友页（form-a · 原型「分享好友」屏）。
///
/// 从「我的」Tab → 应用组「分享好友」push 进入 —— **免登录**（ShareLink 是 guest 接口，游客态
/// 也可访问）。区别于「邀请返佣」：此页无邀请码、无佣金，纯粹分享下载落地页地址。
///
/// **三态**（原型 ok / loading / empty）：
/// - 加载中 → [XbAsyncView] 骨架（list）；
/// - 正常（enabled）→ 分享链接卡（主/备地址复制，复用 [XbShareLinksCard]）+ 多平台下载说明；
/// - 未配置（enabled=false）/ 拉取失败 → [XbEmptyState] link_off「暂无分享地址」。
///
/// **数据**：`shareLinkProvider`（autoDispose）。永不抛（XbResult → AsyncError 由 XbAsyncView 分流）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_invite.dart';
import '../providers/share_link_provider.dart';
import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_share_links.dart';
import '../widgets/xb_theme.dart' show XbTokens;
import '../widgets/xb_ui_kit.dart' show XbBrandScaffold;

class ShareFriendPage extends ConsumerWidget {
  const ShareFriendPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const XbBrandScaffold(
      title: '分享好友',
      body: _ShareBody(),
    );
  }
}

class _ShareBody extends ConsumerWidget {
  const _ShareBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(shareLinkProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(shareLinkProvider);
        // 等本次重拉落定再收起转圈；失败吞掉（错误态由 XbAsyncView 接管，不重复弹）。
        await ref.read(shareLinkProvider.future).catchError(
              (_) =>
                  const XbShareLink(enabled: false, primaryUrl: '', backupUrl: ''),
            );
      },
      child: XbAsyncView(
        loading: async.isLoading,
        error: async.hasError ? async.error : null,
        errorFallback: '加载分享地址失败',
        skeleton: XbSkeletonKind.list,
        onRetry: () => ref.invalidate(shareLinkProvider),
        builder: (context) => _content(context, async.requireValue),
      ),
    );
  }

  Widget _content(BuildContext context, XbShareLink link) {
    // 未配置 / 后台关闭 → 空态（非错误，原型 empty 态）。
    if (!link.enabled) {
      return const XbEmptyState(
        icon: Icons.link_off,
        title: '暂无分享地址',
        description: '管理员尚未配置分享落地页，请稍后再试。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        // 桌面宽窗下内容居中并收到手机级宽度：否则分享卡 / 说明文案会被拉到整屏宽，
        // 说明排成一长行（即「没居中 + 没正确换行很长」）。手机本就窄于此值，无影响。
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const XbGroupLabel('分享链接 · 复制下载各种平台的客户端'),
                XbShareLinksCard(
                  primaryUrl: link.primaryUrl,
                  backupUrl: link.backupUrl,
                ),
                const SizedBox(height: 8),
                const _ShareHint(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 多平台下载说明（原型 info 行）。
class _ShareHint extends StatelessWidget {
  const _ShareHint();

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: brand),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '复制链接发给好友，好友通过链接下载安装客户端，包括 Windows、iOS、Android、Mac、Linux 平台的各种客户端。',
              style: TextStyle(fontSize: 12, height: 1.7, color: t.onv),
            ),
          ),
        ],
      ),
    );
  }
}
