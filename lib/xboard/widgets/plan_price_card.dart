/// R8 套餐价格卡（PlanItem + 周期价格列表 / design R8.2 / D38）。
///
/// **数据源**：反腐层 `getPlans()` → `PlanItem`（已裁剪，零 SDK 穿透 Property 2）。
/// 渲染：套餐名 + 描述 + 流量额度（GB）+ 各周期价格行（货币符号由 flavor 注入）。
///
/// a11y（合规 § D / ι-1）：textScaleFactor 1.5/2.0 不溢出（Wrap + Flexible + ellipsis）；
/// WCAG AA 对比度（价格强调用 primary，正文用 onSurface）。
library;

import 'package:flutter/material.dart';

import '../models/plan_item.dart';
import '../util/period_label.dart';

/// 套餐价格卡。[currencySymbol] 由 flavor 注入（默认 ¥）。
class PlanPriceCard extends StatelessWidget {
  const PlanPriceCard({
    super.key,
    required this.plan,
    this.currencySymbol = '¥',
    this.onSelectPeriod,
  });

  final PlanItem plan;
  final String currencySymbol;

  /// 选择某周期价格的回调（null 时仅展示）。
  final void Function(PricePlan price)? onSelectPeriod;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 套餐名 + 流量额度
            Row(
              children: [
                Expanded(
                  child: Text(
                    plan.name,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${plan.transferEnableGb} GB',
                    style: text.labelMedium?.copyWith(
                        color: scheme.primary, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (plan.description != null && plan.description!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                plan.description!,
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 16),
            // 周期价格行
            ...plan.prices.map((p) => _PriceRow(
                  price: p,
                  currencySymbol: currencySymbol,
                  onTap: onSelectPeriod == null
                      ? null
                      : () => onSelectPeriod!(p),
                )),
          ],
        ),
      ),
    );
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({
    required this.price,
    required this.currencySymbol,
    this.onTap,
  });

  final PricePlan price;
  final String currencySymbol;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(Icons.schedule_rounded,
                size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                planPeriodLabel(price.period),
                style: text.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '$currencySymbol${price.amountYuan.toStringAsFixed(2)}',
                style: text.titleMedium?.copyWith(
                    color: scheme.primary, fontWeight: FontWeight.w700),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: scheme.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
  }
}
