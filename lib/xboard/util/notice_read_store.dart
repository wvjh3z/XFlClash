/// 公告已读状态本地存储（做法二「已读映射表」，用户 2026-06-28 决策）。
///
/// **背景**：Xboard 公告是全局广播，**后端无每用户已读态** → 已读必须客户端本地记。
///
/// **数据结构**：`{公告id: 该 id 已读时的 updatedAt}`（JSON 存 SharedPreferences）。
/// key 绑 userIdHash（同 subscription_cache），换账号天然隔离。
///
/// **未读判定**（[noticeUnread]）：某条公告满足下列任一即"未读/新"——
///   ① id 不在表里（全新公告，含被 backdate 的）；
///   ② updatedAt > 表里记录（老公告被编辑过，内容更新）。
/// 徽标显示 = 拉回的 ≤5 条里任意一条未读（[anyUnread]）。
///
/// **标记已读**（[markRead]）：把当前拉回的每条 `表[id]=updatedAt` 落盘 → 这批全已读。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/xb_notice.dart';

/// 缓存 key 前缀（v1）。完整 key = `<前缀><userIdHash>`。
const String kNoticeReadPrefix = 'xb_notice_read_v1_';

/// 纯函数：单条公告是否未读（id 不在 seen 表 / updatedAt 比记录新）。可单测。
bool noticeUnread(XbNotice n, Map<int, int> seen) {
  final seenUpdatedAt = seen[n.id];
  return seenUpdatedAt == null || n.updatedAt > seenUpdatedAt;
}

/// 纯函数：列表里是否存在未读（徽标显示条件）。可单测。
bool anyUnread(List<XbNotice> notices, Map<int, int> seen) =>
    notices.any((n) => noticeUnread(n, seen));

/// 公告已读状态读写（注入 SharedPreferences 便于测试）。
class NoticeReadStore {
  NoticeReadStore({SharedPreferences? prefs}) : _injected = prefs;

  final SharedPreferences? _injected;

  Future<SharedPreferences> get _prefs async =>
      _injected ?? await SharedPreferences.getInstance();

  static String keyFor(String userIdHash) => '$kNoticeReadPrefix$userIdHash';

  /// 读已读映射表（损坏 JSON → 当空表，不抛）。
  Future<Map<int, int>> load(String userIdHash) async {
    final prefs = await _prefs;
    final raw = prefs.getString(keyFor(userIdHash));
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(int.parse(k), (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// 是否存在未读（拉回列表 vs 本地已读表）。永不抛。
  Future<bool> hasUnread(
    List<XbNotice> notices, {
    required String userIdHash,
  }) async {
    if (notices.isEmpty) return false;
    final seen = await load(userIdHash);
    return anyUnread(notices, seen);
  }

  /// 标记这批公告为已读：`表[id]=updatedAt`。只保留当前返回的 id（后端固定 ≤5 条，
  /// 不让表无限增长）。永不抛（写失败不影响运行）。
  Future<void> markRead(
    List<XbNotice> notices, {
    required String userIdHash,
  }) async {
    try {
      final map = {for (final n in notices) n.id.toString(): n.updatedAt};
      final prefs = await _prefs;
      await prefs.setString(keyFor(userIdHash), jsonEncode(map));
    } catch (_) {
      // 写失败不影响运行（下次仍提示，可接受）。
    }
  }
}
