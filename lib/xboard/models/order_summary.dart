/// 订单领域模型（R9 订单列表 + 详情）。
library;

import 'package:freezed_annotation/freezed_annotation.dart';

import 'xb_domain_types.dart';

part '../generated/models/order_summary.freezed.dart';
part '../generated/models/order_summary.g.dart';

/// 订单摘要（R9 订单列表）。
@freezed
abstract class OrderSummary with _$OrderSummary {
  const factory OrderSummary({
    required String tradeNo,
    String? planName, // OrderModel.orderPlan.name
    required XbPlanPeriod? period, // 旧版 *_price 命名解析自 OrderModel.period（F338）
    required double? totalAmountYuan, // SDK totalAmountInYuan getter（D38）
    required XbOrderStatus? status, // 客户端自有副本（零 SDK 穿透 Property 2）
    required DateTime createdAt,
  }) = _OrderSummary;

  // D11：R11.4 订单首页离线缓存需 json（freezed 默认不生成 fromJson）。
  factory OrderSummary.fromJson(Map<String, dynamic> json) =>
      _$OrderSummaryFromJson(json);
}

extension OrderListReadiness on OrderSummary {
  bool get needsVerification => status == null || period == null || totalAmountYuan == null || tradeNo.trim().isEmpty;
  bool get canContinuePayment => !needsVerification && status == XbOrderStatus.pending;
}

/// Old-plan value is applied before the account balance. When both the net
/// charge and balance deduction are zero, only an explicit surplus_credit can
/// distinguish exact coverage from a surplus that will be returned on opening.
int? appliedOrderSurplusCents({required int net, required int balance, required int surplus, required int? credit}) {
  if (credit == null) return surplus == 0 || net + balance > 0 ? surplus : null;
  if (credit > surplus || credit > 0 && net + balance > 0) return null;
  return surplus - credit;
}

/// 订单详情（OrderSummary + 支付方式 + 全金额字段；**无 paidAt**，第 12 轮）。
@freezed
abstract class OrderDetail with _$OrderDetail {
  const factory OrderDetail({
    required OrderSummary summary,
    PaymentMethodItem? paymentMethod,
    double? balanceAmountYuan, // 主余额抵扣（OrderModel.balanceAmount/100）
    double? surplusAmountYuan, // 旧套餐全部结余，不等同本单抵扣
    double? surplusCreditYuan, // surplus_credit，超出本单的返余额金额；缺失不同于 0
    double? discountAmountYuan, // 面板合计优惠，可包含券与会员折扣
    double? handlingAmountYuan, // 支付手续费
  }) = _OrderDetail;
}
