// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../models/order_summary.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_OrderSummary _$OrderSummaryFromJson(Map<String, dynamic> json) =>
    _OrderSummary(
      tradeNo: json['tradeNo'] as String,
      planName: json['planName'] as String?,
      period: $enumDecode(_$XbPlanPeriodEnumMap, json['period']),
      totalAmountYuan: (json['totalAmountYuan'] as num).toDouble(),
      status: $enumDecode(_$XbOrderStatusEnumMap, json['status']),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$OrderSummaryToJson(_OrderSummary instance) =>
    <String, dynamic>{
      'tradeNo': instance.tradeNo,
      'planName': instance.planName,
      'period': _$XbPlanPeriodEnumMap[instance.period]!,
      'totalAmountYuan': instance.totalAmountYuan,
      'status': _$XbOrderStatusEnumMap[instance.status]!,
      'createdAt': instance.createdAt.toIso8601String(),
    };

const _$XbPlanPeriodEnumMap = {
  XbPlanPeriod.monthly: 'monthly',
  XbPlanPeriod.quarterly: 'quarterly',
  XbPlanPeriod.halfYearly: 'halfYearly',
  XbPlanPeriod.yearly: 'yearly',
  XbPlanPeriod.twoYearly: 'twoYearly',
  XbPlanPeriod.threeYearly: 'threeYearly',
  XbPlanPeriod.onetime: 'onetime',
  XbPlanPeriod.resetTraffic: 'resetTraffic',
};

const _$XbOrderStatusEnumMap = {
  XbOrderStatus.pending: 'pending',
  XbOrderStatus.processing: 'processing',
  XbOrderStatus.cancelled: 'cancelled',
  XbOrderStatus.completed: 'completed',
  XbOrderStatus.discounted: 'discounted',
};
