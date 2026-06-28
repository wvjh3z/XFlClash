/// 公告 provider（form-a 首页公告）。
///
/// **gate**：仅 bootstrapReady + 已登录才拉（公告是 Xboard 已登录接口）；游客/未就绪 → 空态。
/// **永不抛**：拉取失败当作无公告（不影响首页）。
/// **已读判定**：拉回列表 vs 本地已读表（[NoticeReadStore]）→ `hasUnread` 驱动首页徽标。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_notice.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';
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

  static const empty =
      XbNoticeState(notices: <XbNotice>[], hasUnread: false, userIdHash: 'anon');
}

/// 已读状态存储（单例，注入便于测试）。
final noticeReadStoreProvider =
    Provider<NoticeReadStore>((_) => NoticeReadStore());

/// 公告状态（进首页拉一次；autoDispose 让每次进首页都重拉，捕获会话中新发的公告）。
final noticeStateProvider =
    FutureProvider.autoDispose<XbNoticeState>((ref) async {
  // gate：未就绪 / 游客 → 空态（公告是已登录接口，游客无公告）。
  final ready = ref.watch(bootstrapReadyProvider);
  final authed = ref.watch(authStateProvider) == AuthState.authenticated;
  if (!ready || !authed) return XbNoticeState.empty;

  // SDK 未就绪兜底（永不抛）：bootstrapReady 真常态下 xboardServiceProvider 可读；但若
  // SDK 实例尚未注入（早期竞态 / 测试只置 ready 不置 SDK），读它会抛 StateError →
  // 这里吞掉当空态，绝不让公告把首页拖崩。
  final XboardService service;
  try {
    service = ref.watch(xboardServiceProvider);
  } catch (_) {
    return XbNoticeState.empty;
  }
  final result = await service.getNotices();
  final notices = switch (result) {
    XbSuccess(:final data) => data,
    XbFailure() => const <XbNotice>[], // 永不抛：失败当无公告，不影响首页
  };
  if (notices.isEmpty) return XbNoticeState.empty;

  final hash = await service.currentUserIdHash();
  final store = ref.watch(noticeReadStoreProvider);
  final hasUnread = await store.hasUnread(notices, userIdHash: hash);
  return XbNoticeState(notices: notices, hasUnread: hasUnread, userIdHash: hash);
});
