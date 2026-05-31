/// 套餐领域模型（R8 套餐购买，SDK PlanModel → 反腐层裁剪）。
library;

import 'package:freezed_annotation/freezed_annotation.dart';

import 'xb_domain_types.dart';

part '../generated/models/plan_item.freezed.dart';

/// 套餐周期价格（PlanModel.*Price → 折叠成 list；R8.2/D38）。
@freezed
abstract class PricePlan with _$PricePlan {
  const factory PricePlan({
    required XbPlanPeriod period,
    required double amountYuan, // SDK *PriceCents/100
  }) = _PricePlan;
}

/// 套餐列表项。
@freezed
abstract class PlanItem with _$PlanItem {
  const factory PlanItem({
    required int id,
    required String name,
    String? description,
    // 🔴 第12轮：PlanModel.transferEnable 是 double 单位 GB（≠ SubscriptionModel bytes）。
    // 映射 transferEnableGb = plan.transferEnable.toInt()，UI 展示用 GB，勿与字节混算。
    required int transferEnableGb,
    required List<PricePlan> prices, // ≥1，0 项视为下架（R8.2）
  }) = _PlanItem;
}
