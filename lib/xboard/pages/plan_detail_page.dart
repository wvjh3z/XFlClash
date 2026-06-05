/// R8 套餐详情/购买页：HTML 详情 + 周期网格 + 优惠码 + 订单摘要 + 提交订单。
///
/// **数据源**：`PlanItem`（列表页传入）+ 反腐层 `checkCoupon()` / `createOrder()`。
/// 提交订单成功 → 跳 [OrderPaymentPage]（选支付方式 + 立即支付）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/xboard_config.dart';
import '../widgets/xb_theme.dart' show xbPush;
import '../models/plan_item.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../util/period_label.dart';
import '../widgets/xb_ui_kit.dart';
import 'order_payment_page.dart';

class PlanDetailPage extends ConsumerStatefulWidget {
  const PlanDetailPage({super.key, required this.plan});
  final PlanItem plan;

  @override
  ConsumerState<PlanDetailPage> createState() => _PlanDetailPageState();
}

class _PlanDetailPageState extends ConsumerState<PlanDetailPage> {
  late PricePlan _selected;
  final _couponController = TextEditingController();
  CouponInfo? _coupon; // 已校验通过的券
  String? _couponError;
  bool _checkingCoupon = false;
  bool _submitting = false;

  PlanItem get plan => widget.plan;

  /// 可购买周期（排除流量重置包 resetTraffic —— 重置包只在账号卡按需购买，不在下单页选）。
  List<PricePlan> get _purchasablePrices => plan.prices
      .where((p) => p.period != XbPlanPeriod.resetTraffic)
      .toList()
    ..sort((a, b) => a.period.index.compareTo(b.period.index));

  @override
  void initState() {
    super.initState();
    // 默认选最小周期（index 最小 = 周期最短）。
    _selected = _purchasablePrices.first;
  }

  @override
  void dispose() {
    _couponController.dispose();
    super.dispose();
  }

  /// 当前选中周期的小计（元）。
  double get _subtotal => _selected.amountYuan;

  /// 估算优惠金额（元）。type=1 金额(value cents) / type=2 百分比(0-100)。
  /// 仅展示预估，最终金额以后端 checkout 为准。
  double get _discount {
    final c = _coupon;
    if (c == null) return 0;
    if (c.discountAmountCents != null) return c.discountAmountCents! / 100;
    if (c.type == 1) return (c.value / 100).clamp(0, _subtotal);
    if (c.type == 2) return (_subtotal * c.value / 100).clamp(0, _subtotal);
    return 0;
  }

  double get _total => (_subtotal - _discount).clamp(0, _subtotal);

  @override
  Widget build(BuildContext context) {
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: Builder(builder: _buildScaffold),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(plan.name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _header(context),
          const SizedBox(height: 16),
          if (plan.description != null && plan.description!.isNotEmpty)
            _DetailCard(child: _htmlContent(context)),
          const SizedBox(height: 16),
          _DetailCard(child: _periodSection(context)),
          const SizedBox(height: 16),
          _DetailCard(child: _couponSection(context)),
          const SizedBox(height: 16),
          _DetailCard(child: _summarySection(context)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                ),
                child: const Text('返回'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _submitting ? null : _submitOrder,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white))
                      : const Icon(Icons.shopping_cart_checkout_rounded),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  label: const Text('提交订单'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Text(plan.name,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('${plan.transferEnableGb} GB',
              style: text.titleSmall?.copyWith(
                  color: scheme.primary, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _htmlContent(BuildContext context) {
    return Html(
      data: plan.description!,
      style: {
        'body': Style(margin: Margins.zero, padding: HtmlPaddings.zero),
      },
      onLinkTap: (url, _, _) {}, // 详情内链接不跳转（v0.1）。
    );
  }

  Widget _periodSection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sorted = _purchasablePrices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('选择计费周期',
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        // Wrap + 半宽卡片：内容撑高，任何 textScale 都不溢出（不用固定 aspectRatio）。
        LayoutBuilder(builder: (context, constraints) {
          const spacing = 10.0;
          final cardWidth = (constraints.maxWidth - spacing) / 2;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: sorted
                .map((p) => SizedBox(
                      width: cardWidth,
                      child: _periodCard(context, p),
                    ))
                .toList(),
          );
        }),
      ],
    );
  }

  Widget _periodCard(BuildContext context, PricePlan p) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final selected = p.period == _selected.period;
    return InkWell(
      onTap: () {
        setState(() {
          _selected = p;
          // 周期变 → 已校验的券失效（券与周期绑定，需重校验）。
          _coupon = null;
          _couponError = null;
        });
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 1.6,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(planPeriodLabel(p.period),
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurface,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('¥${p.amountYuan.toStringAsFixed(2)}',
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurface,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  Widget _couponSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('优惠码',
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _couponController,
                enabled: !_checkingCoupon,
                decoration: InputDecoration(
                  hintText: '输入优惠码（如有）',
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                  errorText: _couponError,
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _checkingCoupon ? null : _checkCoupon,
              child: _checkingCoupon
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child:
                          CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('验证'),
            ),
          ],
        ),
        if (_coupon != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.check_circle_rounded,
                  size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text('优惠券已应用',
                  style: text.bodySmall?.copyWith(color: scheme.primary)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _summarySection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('订单摘要',
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _summaryRow(context, '小计', '¥${_subtotal.toStringAsFixed(2)}'),
        if (_coupon != null)
          _summaryRow(context, '优惠（预估）', '-¥${_discount.toStringAsFixed(2)}',
              valueColor: scheme.primary),
        const Divider(height: 20),
        Row(
          children: [
            Expanded(
              child: Text('总计',
                  style:
                      text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Text('¥${_total.toStringAsFixed(2)}',
                style: text.titleLarge?.copyWith(
                    color: scheme.primary, fontWeight: FontWeight.w800)),
          ],
        ),
        if (_coupon != null) ...[
          const SizedBox(height: 4),
          Text('* 最终金额以提交订单后为准',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }

  Widget _summaryRow(BuildContext context, String label, String value,
      {Color? valueColor}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 8),
          Text(value,
              style: text.bodyMedium?.copyWith(
                  color: valueColor, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Future<void> _checkCoupon() async {
    final code = _couponController.text.trim();
    if (code.isEmpty) {
      setState(() => _couponError = '请输入优惠码');
      return;
    }
    setState(() {
      _checkingCoupon = true;
      _couponError = null;
    });
    try {
      final result = await ref
          .read(xboardServiceProvider)
          .checkCoupon(code, plan.id, _selected.period);
      switch (result) {
        case XbSuccess(:final data):
          if (data == null) {
            setState(() => _couponError = '优惠码无效');
          } else {
            setState(() => _coupon = data);
          }
        case XbFailure(:final error):
          setState(() => _couponError = error.message);
      }
    } finally {
      if (mounted) setState(() => _checkingCoupon = false);
    }
  }

  Future<void> _submitOrder() async {
    setState(() => _submitting = true);
    try {
      final result = await ref.read(xboardServiceProvider).createOrder(
            plan.id,
            _selected.period,
            couponCode: _coupon != null ? _couponController.text.trim() : null,
          );
      switch (result) {
        case XbSuccess(:final data):
          if (!mounted) return;
          // 跳支付页（订单号），返回时回退到列表。
          xbPush(
            context,
            OrderPaymentPage(tradeNo: data),
            brandColor: Color(XboardConfig.current.brandColor),
            replace: true,
          );
        case XbFailure(:final error):
          _toast('提交订单失败：${error.message}');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 详情区卡片外壳。
class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
