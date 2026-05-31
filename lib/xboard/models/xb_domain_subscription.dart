/// 订阅领域模型（D70 命名 / R6.8 公式）。
///
/// 命名 `XbDomainSubscription`（D70，避免与 SDK `SubscriptionModel` / FlClash `SubscriptionInfo` /
/// panel `SubscriptionInfo` 三层混淆 F217/F222）。数据源 = SDK `getSubscription()`（裸字节 F408）。
///
/// **离线缓存 json（D11/决策 #13）**：freezed 默认不生成 json，显式加 fromJson + json_serializable
/// 联动。缓存写入前 PII 脱敏（email 掩码 / uuid 前 8 位，R11.4），不明文落 SharedPreferences（NFR-3）。
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part '../generated/models/xb_domain_subscription.freezed.dart';
part '../generated/models/xb_domain_subscription.g.dart';

@freezed
abstract class XbDomainSubscription with _$XbDomainSubscription {
  const factory XbDomainSubscription({
    required String email,
    required String uuid,
    String? planName,
    required int totalBytes, // SubscriptionModel.transferEnable（字节 F408）
    required int usedBytes, // (u ?? 0) + (d ?? 0)（字节 R6.8）
    DateTime? expiredAt, // null = 长期有效（一次性套餐 D51）
    DateTime? nextResetAt, // null = 流量套餐/不重置（D51）
    int? resetDay, // 月内重置日（F408 v1.13.0；≠ nextResetAt.day）
    int? planId,
  }) = _XbDomainSubscription;

  const XbDomainSubscription._();

  factory XbDomainSubscription.fromJson(Map<String, dynamic> json) =>
      _$XbDomainSubscriptionFromJson(json);

  /// 剩余流量（字节，clamp 防负）。
  int get remainingBytes => (totalBytes - usedBytes).clamp(0, totalBytes);

  /// 无套餐（R6.3 / R7.10 F189）。
  bool get hasNoPlan => planId == null || totalBytes == 0;
}
