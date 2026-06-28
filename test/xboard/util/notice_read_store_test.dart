/// 公告已读状态契约测试（做法二「已读映射表」）。
///
/// 覆盖判定四态（新 id / 编辑过 updatedAt 变 / 没变 / 比记录旧）+ 标记已读 + 换账号隔离 +
/// backdate 边界（新 id 即使 updatedAt 很旧也算未读）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/models/xb_notice.dart';
import 'package:fl_clash/xboard/util/notice_read_store.dart';

XbNotice _n(int id, int updatedAt) => XbNotice(
      id: id,
      title: 'n$id',
      content: '<p>x</p>',
      createdAt: DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000),
      updatedAt: updatedAt,
    );

void main() {
  group('noticeUnread / anyUnread（纯函数）', () {
    test('id 不在表 → 未读（含 backdate 的新公告）', () {
      expect(noticeUnread(_n(5, 100), {}), isTrue);
      expect(noticeUnread(_n(5, 1), {3: 999}), isTrue); // 新 id 即使时间很旧
    });
    test('updatedAt > 记录 → 未读（被编辑过）', () {
      expect(noticeUnread(_n(5, 200), {5: 100}), isTrue);
    });
    test('updatedAt == 记录 → 已读', () {
      expect(noticeUnread(_n(5, 100), {5: 100}), isFalse);
    });
    test('updatedAt < 记录 → 已读', () {
      expect(noticeUnread(_n(5, 50), {5: 100}), isFalse);
    });
    test('anyUnread：任意一条未读即 true', () {
      final list = [_n(1, 10), _n(2, 20)];
      expect(anyUnread(list, {1: 10, 2: 20}), isFalse); // 全已读
      expect(anyUnread(list, {1: 10}), isTrue); // id2 未读
      expect(anyUnread(list, {1: 10, 2: 5}), isTrue); // id2 被编辑
    });
  });

  group('NoticeReadStore（注入 SharedPreferences）', () {
    late NoticeReadStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = NoticeReadStore(prefs: await SharedPreferences.getInstance());
    });

    test('空表 → 全部未读；markRead 后 → 已读', () async {
      final list = [_n(1, 10), _n(2, 20)];
      expect(await store.hasUnread(list, userIdHash: 'a'), isTrue);
      await store.markRead(list, userIdHash: 'a');
      expect(await store.hasUnread(list, userIdHash: 'a'), isFalse);
    });

    test('已读后来新公告 → 又未读', () async {
      final list = [_n(1, 10)];
      await store.markRead(list, userIdHash: 'a');
      expect(await store.hasUnread(list, userIdHash: 'a'), isFalse);
      final withNew = [_n(1, 10), _n(2, 30)];
      expect(await store.hasUnread(withNew, userIdHash: 'a'), isTrue);
    });

    test('已读后老公告被编辑（updatedAt 推进）→ 又未读', () async {
      await store.markRead([_n(1, 10)], userIdHash: 'a');
      expect(await store.hasUnread([_n(1, 99)], userIdHash: 'a'), isTrue);
    });

    test('换账号隔离：a 标记已读不影响 b', () async {
      final list = [_n(1, 10)];
      await store.markRead(list, userIdHash: 'a');
      expect(await store.hasUnread(list, userIdHash: 'a'), isFalse);
      expect(await store.hasUnread(list, userIdHash: 'b'), isTrue);
    });

    test('空列表 → 无未读', () async {
      expect(await store.hasUnread(const [], userIdHash: 'a'), isFalse);
    });

    test('markRead 只保留当前返回的 id（表不膨胀）', () async {
      await store.markRead([_n(1, 10), _n(2, 20)], userIdHash: 'a');
      await store.markRead([_n(3, 30)], userIdHash: 'a'); // 新一批仅 id3
      final seen = await store.load('a');
      expect(seen.keys.toSet(), {3});
    });
  });
}
