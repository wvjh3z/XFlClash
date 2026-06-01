/// W9.3 — 缓存 schema fail-safe（DD-22）：v1 key 命名 + 旧 key miss + 损坏 delete+refetch。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';
import 'package:fl_clash/xboard/util/subscription_cache.dart';

void main() {
  late SharedPreferences prefs;
  late SubscriptionCache cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    cache = SubscriptionCache(prefs: prefs);
  });

  test('DD-22：缓存 key 含 _v1_ 段 + userIdHash', () {
    final key = SubscriptionCache.keyFor(userIdHashFromToken('tok'));
    expect(key.startsWith('xb_subscription_cache_v1_'), isTrue);
    expect(key, contains(userIdHashFromToken('tok')));
  });

  test('旧 v0 key 残留 → v1 读 miss（不误用旧 schema）', () async {
    // 模拟旧版本残留 key。
    await prefs.setString('xb_subscription_cache_v0_${userIdHashFromToken('tok')}',
        '{"email":"old"}');
    final read = await cache.read(token: 'tok'); // 读 v1
    expect(read, isNull); // v1 miss，走 SDK 重拉
  });

  test('损坏 JSON → fromJson catch + delete + refetch（返 null）', () async {
    final key = SubscriptionCache.keyFor(userIdHashFromToken('tok'));
    await prefs.setString(key, '{corrupt');
    expect(await cache.read(token: 'tok'), isNull);
    expect(prefs.getString(key), isNull); // 已 delete
  });

  test('合法 v1 缓存 → 正常读回（PII 脱敏）', () async {
    await cache.write(
        const XbDomainSubscription(
            email: 'alice@b.com', uuid: 'uuid1234x', totalBytes: 100, usedBytes: 20),
        token: 'tok');
    final read = await cache.read(token: 'tok');
    expect(read, isNotNull);
    expect(read!.email, 'al***@b.com'); // 脱敏值
    expect(read.totalBytes, 100);
  });
}
