/// 公告 provider（form-a 首页公告）。
///
/// **gate**：仅 bootstrapReady + 已登录才拉（公告是 Xboard 已登录接口）；游客/未就绪 → 空态。
/// 失败走 AsyncError，只有成功的空列表表示无公告。
/// **已读判定**：拉回列表 vs 本地已读表（[NoticeReadStore]）→ `hasUnread` 驱动首页徽标。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_notice.dart';
import '../models/xb_result.dart';
import '../util/notice_read_store.dart';
import 'auth_state_provider.dart';
import 'xboard_providers.dart';

/// 公告状态：列表 + 是否有未读 + 当前 userIdHash（供"打开即已读"标记用，免二次取 hash）。
class XbNoticeState {
  const XbNoticeState({
    required this.notices,
    required this.hasUnread,
    required this.userIdHash,
  });

  final List<XbNotice> notices;
  final bool hasUnread;
  final String userIdHash;

  static const empty = XbNoticeState(
    notices: <XbNotice>[],
    hasUnread: false,
    userIdHash: 'anon',
  );
}

/// 已读状态存储（单例，注入便于测试）。
final noticeReadStoreProvider = Provider<NoticeReadStore>(
  (_) => NoticeReadStore(),
);

/// 首次读取以及显式刷新；首页保活时由徽标处理可见性及恢复。
final noticeStateProvider = FutureProvider.autoDispose<XbNoticeState>((
  ref,
) async {
  // gate：未就绪 / 游客 → 空态（公告是已登录接口，游客无公告）。
  final ready = ref.watch(bootstrapReadyProvider);
  final authed = ref.watch(authStateProvider) == AuthState.authenticated;
  if (!ready || !authed) return XbNoticeState.empty;

  final service = ref.watch(xboardServiceProvider);
  final store = ref.watch(noticeReadStoreProvider);
  final result = await service.getNotices();
  final notices = switch (result) {
    XbSuccess(:final data) => data,
    XbFailure(:final error) => throw error,
  };
  if (notices.isEmpty) return XbNoticeState.empty;
  if (!ref.mounted) return XbNoticeState.empty;

  final hash = await service.currentUserIdHash();
  final hasUnread = await store.hasUnread(notices, userIdHash: hash);
  return XbNoticeState(
    notices: notices,
    hasUnread: hasUnread,
    userIdHash: hash,
  );
}, retry: (retryCount, error) => null);
