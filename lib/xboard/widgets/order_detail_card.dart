/// R9 订单详情卡（OrderDetail / design R9 / 第12轮 无 paidAt）。
///
/// **数据源**：反腐层 `getOrder(tradeNo)` → `OrderDetail`（零 SDK 穿透 Property 2）。
/// 渲染：订单号 + 套餐名 + 周期 + 状态徽章 + 创建时间 + 金额拆分（余额/结余/优惠/手续费/合计）。
///
/// a11y（合规 § D / ι-1）：textScaleFactor 1.5/2.0 不溢出（Flexible + ellipsis）；
/// 状态徽章颜色满足 WCAG AA（终态用语义色 + 文字双编码，不仅靠颜色区分）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/order_summary.dart';
import '../models/xb_domain_types.dart';
import '../util/period_label.dart';

/// 订单详情卡。[currencySymbol] 由 flavor 注入（默认 ¥）。
class OrderDetailCard extends StatelessWidget {
  const OrderDetailCard({
    super.key,
    required this.detail,
    this.currencySymbol = '¥',
  });

  final OrderDetail detail;
  final String currencySymbol;

  String _money(double? v) =>
      v == null ? '-' : '$currencySymbol${v.toStringAsFixed(2)}';

  String _fmtDateTime(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final s = detail.summary;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：套餐名 + 状态徽章
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.planName ?? '套餐订单',
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: s.status),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            // 订单信息段
            _InfoRow(label: '套餐周期', value: planPeriodLabel(s.period)),
            _InfoRow(label: '创建时间', value: _fmtDateTime(s.createdAt)),
            _InfoRow(label: '订单状态', value: orderStatusLabel(s.status)),
            _CopyableRow(label: '订单号', value: s.tradeNo),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            // 金额拆分
            if (detail.balanceAmountYuan != null)
              _AmountRow(label: '余额抵扣', value: _money(detail.balanceAmountYuan)),
            if (detail.surplusAmountYuan != null)
              _AmountRow(label: '结余抵扣', value: _money(detail.surplusAmountYuan)),
            if (detail.discountAmountYuan != null)
              _AmountRow(label: '优惠券', value: _money(detail.discountAmountYuan)),
            if (detail.handlingAmountYuan != null)
              _AmountRow(label: '手续费', value: _money(detail.handlingAmountYuan)),
            if (detail.paymentMethod != null)
              _AmountRow(label: '支付方式', value: detail.paymentMethod!.name),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 12),
            // 合计
            Row(
              children: [
                Text('应付合计',
                    style: text.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                Flexible(
                  child: Text(
                    _money(s.totalAmountYuan),
                    style: text.titleLarge?.copyWith(
                        color: scheme.primary, fontWeight: FontWeight.w800),
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label,
              style:
                  text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const Spacer(),
          Flexible(
            child: Text(value,
                style:
                    text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// 信息行（label 左 / value 右，value 可换行不截断）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                textAlign: TextAlign.right,
                softWrap: true),
          ),
        ],
      ),
    );
  }
}

/// 订单号行（可点击复制到剪贴板）。
class _CopyableRow extends StatelessWidget {
  const _CopyableRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('订单号已复制')),
                );
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(value,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                        textAlign: TextAlign.right,
                        softWrap: true),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.copy_rounded,
                      size: 15, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态徽章：色 + 文字双编码（a11y 不仅靠颜色）。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final XbOrderStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      XbOrderStatus.completed ||
      XbOrderStatus.discounted =>
        (scheme.primary.withValues(alpha: 0.14), scheme.primary),
      XbOrderStatus.cancelled =>
        (scheme.error.withValues(alpha: 0.14), scheme.error),
      _ => (scheme.tertiary.withValues(alpha: 0.16), scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        orderStatusLabel(status),
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: fg, fontWeight: FontWeight.w700),
      ),
    );
  }
}
