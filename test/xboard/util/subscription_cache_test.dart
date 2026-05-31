/// W4.4 — R6 离线缓存 success-write + PII 脱敏 + 损坏处理（决策 #11/#13 / DD-22 / ε4）。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';
import 'package:fl_clash/xboard/util/subscription_cache.dart';

void main() {
  late SharedPreferences prefs;
  late SubscriptionCache cache;

  const sub = XbDomainSubscription(
    email: 'alice@example.com',
    uuid: 'uuid1234-5678-9abc',
    planName: 'Pro',
    totalBytes: 1000,
    usedBytes: 300,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    cache = SubscriptionCache(prefs: prefs);
  });

  test('write → read round-trip（脱敏后）', () async {
    await cache.write(sub, token: 'tok');
    final read = await cache.read(token: 'tok');
    expect(read, isNotNull);
    expect(read!.planName, 'Pro');
    expect(read.totalBytes, 1000);
    // PII 已脱敏
    expect(read.email, 'al***@example.com');
    expect(read.uuid, 'uuid1234***');
  });

  test('PII 不明文落盘（grep 原始 email/uuid 不存在）', () async {
    await cache.write(sub, token: 'tok');
    final raw = prefs.getString(SubscriptionCache.keyFor(userIdHashFromToken('tok')))!;
    expect(raw.contains('alice@example.com'), isFalse);
    expect(raw.contains('uuid1234-5678-9abc'), isFalse);
    expect(raw.contains('al***@example.com'), isTrue); // 脱敏值在
  });

  test('key 绑 userIdHash → 切账号 miss', () async {
    await cache.write(sub, token: 'tokA');
    final readB = await cache.read(token: 'tokB'); // 不同 token
    expect(readB, isNull);
  });

  test('损坏 JSON → delete + 返 null（决策 #13）', () async {
    final key = SubscriptionCache.keyFor(userIdHashFromToken('tok'));
    await prefs.setString(key, '{not valid json');
    final read = await cache.read(token: 'tok');
    expect(read, isNull);
    expect(prefs.getString(key), isNull); // 已删
  });

  test('clear → 删缓存', () async {
    await cache.write(sub, token: 'tok');
    await cache.clear(token: 'tok');
    expect(await cache.read(token: 'tok'), isNull);
  });

  test('无缓存 → read 返 null', () async {
    expect(await cache.read(token: 'tok'), isNull);
  });
}
