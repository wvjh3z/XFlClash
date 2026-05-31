/// R6 订阅离线缓存（决策 #11 success-write + 决策 #13 反序列化失败处理 + DD-22 v1 + ε4 PII 脱敏）。
///
/// **写**：getSubscription success 后写 `xb_subscription_cache_v1_<userIdHash>`；写盘前 PII 脱敏
/// （email/uuid 掩码，不明文落 SharedPreferences，NFR-3）。
/// **读**：离线态读缓存反序列化（决策 #13：损坏 JSON → delete + 返 null 触发 refetch）。
/// **key 绑 userIdHash**（ε4）：切账号天然 miss 旧用户缓存。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/xb_domain_subscription.dart';
import 'pii_mask.dart';

/// 缓存 key 前缀（DD-22 v1）。完整 key = `<前缀><userIdHash>`。
const String kSubscriptionCachePrefix = 'xb_subscription_cache_v1_';

/// 订阅离线缓存读写（注入 SharedPreferences 便于测试）。
class SubscriptionCache {
  SubscriptionCache({SharedPreferences? prefs}) : _injected = prefs;

  final SharedPreferences? _injected;

  Future<SharedPreferences> get _prefs async =>
      _injected ?? await SharedPreferences.getInstance();

  static String keyFor(String userIdHash) =>
      '$kSubscriptionCachePrefix$userIdHash';

  /// 写缓存（PII 脱敏后 jsonEncode）。[token] 派生 userIdHash。
  Future<void> write(XbDomainSubscription sub, {required String? token}) async {
    final userIdHash = userIdHashFromToken(token);
    final masked = sub.copyWith(
      email: maskEmail(sub.email),
      uuid: maskUuid(sub.uuid),
    );
    final prefs = await _prefs;
    await prefs.setString(keyFor(userIdHash), jsonEncode(masked.toJson()));
  }

  /// 读缓存（决策 #13：损坏 → delete + 返 null）。返回的 email/uuid 已是脱敏值。
  Future<XbDomainSubscription?> read({required String? token}) async {
    final userIdHash = userIdHashFromToken(token);
    final prefs = await _prefs;
    final raw = prefs.getString(keyFor(userIdHash));
    if (raw == null) return null;
    try {
      return XbDomainSubscription.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await prefs.remove(keyFor(userIdHash)); // 决策 #13 损坏即删
      return null;
    }
  }

  /// 清缓存（logout step 2）。
  Future<void> clear({required String? token}) async {
    final userIdHash = userIdHashFromToken(token);
    final prefs = await _prefs;
    await prefs.remove(keyFor(userIdHash));
  }
}
