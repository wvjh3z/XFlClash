/// R8 套餐详情/购买页：HTML 详情 + 周期网格 + 优惠码 + 订单摘要 + 提交订单。
///
/// **数据源**：`PlanItem`（列表页传入）+ 反腐层 `checkCoupon()` / `createOrder()`。
/// 提交订单成功 → 跳 [OrderPaymentPage]（选支付方式 + 立即支付）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/xboard_config.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_theme.dart' show xbPush, XbTokens;
import '../models/plan_item.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../util/period_label.dart';
import '../widgets/xb_ui_kit.dart';
import 'order_payment_page.dart';
import 'pending_order_section.dart';

class PlanDetailPage extends ConsumerStatefulWidget {
  const PlanDetailPage({super.key, required this.plan, this.renew = false});
  final PlanItem plan;

  /// 续费模式（原型图 13）：锁定当前套餐只选周期，标题/文案/按钮换续费语义,
  /// 周期卡显示基于月付单价的折扣（套餐无月付则不显示折扣）。
  final bool renew;

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

  /// 月付单价（元）—— 续费折扣基数；套餐无月付则 null（不计算折扣）。
  double? get _monthlyUnitPrice {
    for (final p in plan.prices) {
      if (p.period == XbPlanPeriod.monthly) return p.amountYuan;
    }
    return null;
  }

  /// 某周期相对月付的折扣百分比（省 N%）；无月付基数 / 非按月周期 / 无优惠 → null。
  int? _discountPercent(PricePlan p) {
    final monthly = _monthlyUnitPrice;
    if (monthly == null || monthly <= 0) return null;
    final months = planPeriodMonths(p.period);
    if (months == null || months <= 1) return null; // 月付本身不标
    final full = monthly * months;
    if (full <= 0) return null;
    final save = ((1 - p.amountYuan / full) * 100).round();
    return save > 0 ? save : null;
  }

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
    return Scaffold(
      appBar: AppBar(title: Text(widget.renew ? '续费当前套餐' : plan.name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          const PendingOrderSection(),
          _headerCard(context),
          const SizedBox(height: 14),
          XbSectionCard(
              title: widget.renew ? '选择续费时长' : '选择计费周期',
              child: _periodSection(context)),
          const SizedBox(height: 14),
          XbSectionCard(title: '优惠码', child: _couponSection(context)),
          const SizedBox(height: 14),
          XbSectionCard(title: '订单摘要', child: _summarySection(context)),
        ],
      ),
      bottomNavigationBar: XbBottomActionBar(
        secondaryLabel: '返回',
        primaryLabel: widget.renew ? '确认续费' : '提交订单',
        primaryIcon: Icons.shopping_cart_checkout_rounded,
        primaryLoading: _submitting,
        onPrimary: _submitOrder,
      ),
    );
  }

  /// 头部卡：购买=套餐名+GB角标+HTML详情；续费=当前套餐条（锁定,只延期不改内容,原型图13）。
  Widget _headerCard(BuildContext context) {
    final t = XbTokens.of(context);
    if (widget.renew) {
      final scheme = Theme.of(context).colorScheme;
      return XbCard(
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.confirmation_number_outlined,
                  color: scheme.primary, size: 21),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${plan.name} · ${plan.transferEnableGb} GB',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: t.on)),
                  const SizedBox(height: 2),
                  Text('续费不改变套餐内容，仅延长有效期',
                      style: TextStyle(fontSize: 11, color: t.onv)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final hasHtml = plan.description != null && plan.description!.isNotEmpty;
    return XbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(plan.name,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: t.on)),
              ),
              const SizedBox(width: 8),
              XbTag('${plan.transferEnableGb} GB'),
            ],
          ),
          if (hasHtml) ...[
            const SizedBox(height: 10),
            _htmlContent(context),
          ],
        ],
      ),
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
    final sorted = _purchasablePrices;
    // Wrap + 半宽卡片：内容撑高，任何 textScale 都不溢出（不用固定 aspectRatio）。
    return LayoutBuilder(builder: (context, constraints) {
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
    });
  }

  Widget _periodCard(BuildContext context, PricePlan p) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = p.period == _selected.period;
    // 续费模式：基于月付单价算折扣「省 N%」（套餐无月付/无优惠则不显示）。
    final savePct = widget.renew ? _discountPercent(p) : null;
    return XbSelectableOption(
      selected: selected,
      tag: savePct != null ? '省 $savePct%' : null,
      onTap: () {
        setState(() {
          _selected = p;
          // 周期变 → 已校验的券失效（券与周期绑定，需重校验）。
          _coupon = null;
          _couponError = null;
        });
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(planPeriodLabel(p.period),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  color: selected ? scheme.primary : t.on,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('¥${p.amountYuan.toStringAsFixed(2)}',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 19,
                  color: selected ? scheme.primary : t.on,
                  fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _couponSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        XbKeyValueRow(label: '小计', value: '¥${_subtotal.toStringAsFixed(2)}'),
        if (_coupon != null)
          XbKeyValueRow(
              label: '优惠（预估）',
              value: '-¥${_discount.toStringAsFixed(2)}',
              valueColor: scheme.primary),
        const XbHairline(margin: 10),
        XbKeyValueRow(
            label: '总计', value: '¥${_total.toStringAsFixed(2)}', total: true),
        if (_coupon != null) ...[
          const SizedBox(height: 4),
          Text('* 最终金额以提交订单后为准',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ],
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
