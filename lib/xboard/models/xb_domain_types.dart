/// 反腐层辅助领域类型（XboardService 签名引用，design「反腐层辅助类型」+ Data Models）。
///
/// **零 SDK 类型穿透**（conventions §2.1 / Property 2）：UI / Provider 只见这些客户端类型。
///
/// 本文件聚合 W2 阶段需要的小型自包含类型（enum + 简单 freezed）：
/// `XbPlanPeriod` / `XbOrderStatus` / `XbCheckLogin` / `XbPagedList<T>` / `PaymentMethodItem` /
/// `IpMirrorConfigUi` / `CouponInfo`。领域实体（XbDomainSubscription / PlanItem / OrderSummary /
/// OrderDetail / CheckoutOutcomeUi）在各自 wave（W4/W6/W7）单独文件填实。
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part '../generated/models/xb_domain_types.freezed.dart';

/// 套餐周期 — 客户端自有副本（值对齐 SDK PlanPeriod 旧版 `*_price` 命名，F338）。
enum XbPlanPeriod {
  monthly,
  quarterly,
  halfYearly,
  yearly,
  twoYearly,
  threeYearly,
  onetime,
  resetTraffic,
}

/// 订单状态 — 客户端自有副本（映射 SDK `OrderStatus` raw 0-4，第 12 轮 / OrderStatus 收口）。
/// pending(0) / processing(1) / cancelled(2) / completed(3) / discounted(4)。
/// 终态 = cancelled / completed / discounted。
enum XbOrderStatus { pending, processing, cancelled, completed, discounted }

/// checkLogin 轻量返回（R7.4 IpAuth 兜底）。
@freezed
abstract class XbCheckLogin with _$XbCheckLogin {
  const factory XbCheckLogin({required bool isLogin}) = _XbCheckLogin;
}

/// 客户端切片分页容器（R9 / SDK PaginatedList.data → items 重命名，第 12 轮）。
@freezed
abstract class XbPagedList<T> with _$XbPagedList<T> {
  const factory XbPagedList({
    required List<T> items,
    required int page,
    required int pageSize,
    required int total,
  }) = _XbPagedList<T>;
}

/// 支付方式领域模型（R8 / 映射 SDK PaymentMethodModel；handlingFeeFixed(cents)/100、handlingFeePercent 原值）。
@freezed
abstract class PaymentMethodItem with _$PaymentMethodItem {
  const factory PaymentMethodItem({
    required String id,
    required String name,
    String? icon,
    double? feeFixedYuan,
    double? feePercent,
  }) = _PaymentMethodItem;
}

/// IpMirror 配置（R7.13.bis / 来源 SDK fetchMirrorList）。
@freezed
abstract class IpMirrorConfigUi with _$IpMirrorConfigUi {
  const factory IpMirrorConfigUi({
    required bool enabled,
    required List<String> urls,
    required Duration throttle,
    required Duration fetchTimeout,
  }) = _IpMirrorConfigUi;
}

/// 优惠券领域模型（R8 / 来源 SDK CouponModel；type/value int? → ?? 兜底）。
@freezed
abstract class CouponInfo with _$CouponInfo {
  const factory CouponInfo({
    required String code,
    required int type, // 1=金额折扣(cents) / 2=百分比(0-100)
    required int value,
    int? discountAmountCents, // 来自下单后 OrderModel.discountAmount（非 CouponModel）
    DateTime? endedAt,
  }) = _CouponInfo;
}
