/// XbPlanPeriod / XbOrderStatus 显示文案（R8/R9 UI；v0.1 中文，i18n 留 W8.7 arb）。
library;

import '../models/xb_domain_types.dart';

/// 套餐周期中文标签（R8.2）。
String planPeriodLabel(XbPlanPeriod period) => switch (period) {
      XbPlanPeriod.monthly => '月付',
      XbPlanPeriod.quarterly => '季付',
      XbPlanPeriod.halfYearly => '半年付',
      XbPlanPeriod.yearly => '年付',
      XbPlanPeriod.twoYearly => '两年付',
      XbPlanPeriod.threeYearly => '三年付',
      XbPlanPeriod.onetime => '一次性',
      XbPlanPeriod.resetTraffic => '流量重置包',
    };

/// 订单状态中文标签（R9）。
String orderStatusLabel(XbOrderStatus status) => switch (status) {
      XbOrderStatus.pending => '待支付',
      XbOrderStatus.processing => '处理中',
      XbOrderStatus.cancelled => '已取消',
      XbOrderStatus.completed => '已完成',
      XbOrderStatus.discounted => '已抵扣',
    };

/// 周期对应月数（续费折扣计算用：省 = 1 - 实付/(月单价×月数)）。
/// 非按月周期（onetime/resetTraffic）返回 null（不参与折扣计算）。
int? planPeriodMonths(XbPlanPeriod period) => switch (period) {
      XbPlanPeriod.monthly => 1,
      XbPlanPeriod.quarterly => 3,
      XbPlanPeriod.halfYearly => 6,
      XbPlanPeriod.yearly => 12,
      XbPlanPeriod.twoYearly => 24,
      XbPlanPeriod.threeYearly => 36,
      XbPlanPeriod.onetime => null,
      XbPlanPeriod.resetTraffic => null,
    };

