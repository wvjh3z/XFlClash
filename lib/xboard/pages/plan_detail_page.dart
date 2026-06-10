/// R8 套餐详情/购买页：HTML 详情 + 周期网格 + 优惠码 + 订单摘要 + 提交订单。
///
/// **数据源**：`PlanItem`（列表页传入）+ 反腐层 `checkCoupon()` / `createOrder()`。
/// 提交订单成功 → 跳 [OrderPaymentPage]（选支付方式 + 立即支付）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbToast, xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush, xbShowDialog, XbTokens;
import '../models/plan_item.dart';
import '../models/xb_domain_subscription.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/user_profile_provider.dart';
import '../providers/xboard_providers.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../util/period_label.dart';
import '../widgets/xb_ui_kit.dart';
import 'order_payment_page.dart';
import 'pending_order_section.dart';
import 'plan_list_page.dart';

/// 是否需弹「更换套餐」确认（纯函数，可单测）。同时满足才弹：
/// ① 非续费模式；② 当前有套餐（planId 非空、有流量）；③ 未到期（expiredAt==null 长期有效
/// 或在 [now] 之后）；④ 所选套餐 [newPlanId] ≠ 当前套餐。任一不满足 → 视为正常下单，不提示。
bool shouldConfirmPlanSwitch({
  required XbDomainSubscription? current,
  required int newPlanId,
  required bool isRenew,
  required DateTime now,
}) {
  if (isRenew) return false;
  final sub = current;
  if (sub == null || sub.hasNoPlan || sub.planId == null) return false;
  // 已到期（expiredAt 非空且不在未来）→ 视为全新选购，不提示。
  final expired = sub.expiredAt != null && !sub.expiredAt!.isAfter(now);
  if (expired) return false;
  return sub.planId != newPlanId; // 仅换成不同套餐才提示。
}

/// 续费加载外壳：按 [planId] 拉套餐 → 锁定当前套餐 → 渲染续费详情页。
///
/// **交互统一**（§11 系统化修复）：续费与「购买/更改」走同一模式——点击**立即跳转**，由目标
/// 页用 [XbAsyncView] 自己加载转圈，而非在「我的」页预拉数据 + 弹遮罩。找不到当前套餐（已下架）
/// → 回退展示套餐列表（不阻断续费意图）。
class PlanRenewLoader extends ConsumerStatefulWidget {
  const PlanRenewLoader({super.key, required this.planId});

  final int planId;

  @override
  ConsumerState<PlanRenewLoader> createState() => _PlanRenewLoaderState();
}

class _PlanRenewLoaderState extends ConsumerState<PlanRenewLoader> {
  late Future<List<PlanItem>> _future;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<PlanItem>> _load() async {
    final result = await ref.read(xboardServiceProvider).getPlans();
    return switch (result) {
      XbSuccess(:final data) => data,
      XbFailure(:final error) => throw error,
    };
  }

  void _reload() {
    setState(() {
      _retrying = true;
      _future = _load();
    });
    _future.whenComplete(() {
      if (mounted) setState(() => _retrying = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PlanItem>>(
      future: _future,
      builder: (context, snap) {
        final done = snap.connectionState == ConnectionState.done;
        // 数据就绪 → 直接返回目标页（自带 XbBrandScaffold/AppBar），避免嵌套脚手架。
        if (done && !_retrying && snap.error == null) {
          final plans = snap.data ?? const <PlanItem>[];
          final current =
              plans.where((p) => p.id == widget.planId).firstOrNull;
          return current != null
              ? PlanDetailPage(plan: current, renew: true)
              : const PlanListPage();
        }
        // 加载 / 重试 / 错误：用带返回栏的脚手架 + XbAsyncView 转圈（与购买页转圈口径一致）。
        return XbBrandScaffold(
          title: '续费当前套餐',
          body: XbAsyncView(
            loading: !done && !_retrying,
            retrying: _retrying,
            error: done ? snap.error : null,
            errorFallback: '加载套餐失败',
            onRetry: _reload,
            builder: (_) => const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

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
    return XbBrandScaffold(
      title: widget.renew ? '续费当前套餐' : plan.name,
      bottomNavigationBar: XbBottomActionBar(
        secondaryLabel: '返回',
        primaryLabel: widget.renew ? '确认续费' : '提交订单',
        primaryIcon: Icons.shopping_cart_checkout_rounded,
        primaryLoading: _submitting,
        onPrimary: _submitOrder,
      ),
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
            XbIconBadge(
              icon: Icons.confirmation_number_outlined,
              size: 42,
              radius: XbTokens.rMd,
              background: scheme.primary.withValues(alpha: 0.14),
              iconColor: scheme.primary,
              iconSize: 21,
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
                          fontWeight: FontWeight.w500,
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
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
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
      return Padding(
        // 顶部留白：让首行「省 N%」浮标（top:-9 浮出卡片上方）不顶到「选择计费周期」标题。
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: spacing,
          // runSpacing 需大于浮标上探高度（top:-9 + 标签高 ~20 → 约 11px 探出），否则下一行
          // 浮标侵入上一行底部，看起来「挤压/大小不齐」。给足 18 行距。
          runSpacing: 18,
          children: sorted
              .map((p) => SizedBox(
                    width: cardWidth,
                    child: _periodCard(context, p),
                  ))
              .toList(),
        ),
      );
    });
  }

  Widget _periodCard(BuildContext context, PricePlan p) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = p.period == _selected.period;
    // 基于月付单价算折扣「省 N%」（套餐无月付/无优惠则不显示）；购买、续费两模式都显示。
    final savePct = _discountPercent(p);
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
                  fontSize: 13.5,
                  color: selected ? scheme.primary : t.on,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(xbYuan(p.amountYuan),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 18,
                  color: selected ? scheme.primary : t.on,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()])),
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
            // 验证按钮：次级（品牌淡底描边），让输入框成为该行主体（主次平衡，原型 .cbtn）。
            OutlinedButton(
              onPressed: _checkingCoupon ? null : _checkCoupon,
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.primary,
                backgroundColor: scheme.primary.withValues(alpha: 0.10),
                side: BorderSide(
                    color: scheme.primary.withValues(alpha: 0.30), width: 1.5),
              ),
              child: _checkingCoupon
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: scheme.primary))
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
              Expanded(
                child: Text('优惠券已应用',
                    style: text.bodySmall?.copyWith(color: scheme.primary)),
              ),
              // 取消已应用的优惠券（清空券 + 输入框 + 错误）。
              GestureDetector(
                onTap: _clearCoupon,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 2),
                  child: Text('取消',
                      style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600)),
                ),
              ),
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
        XbKeyValueRow(label: '小计', value: xbYuan(_subtotal)),
        if (_coupon != null)
          XbKeyValueRow(
              label: '优惠（预估）',
              value: xbYuanMinus(_discount),
              valueColor: scheme.primary),
        const XbHairline(margin: 10),
        XbKeyValueRow(
            label: '总计', value: xbYuan(_total), total: true),
        if (_coupon != null) ...[
          const SizedBox(height: 4),
          Text('* 最终金额以提交订单后为准',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }

  /// 取消已应用的优惠券：清空券 + 输入框 + 错误提示，金额恢复原价。
  void _clearCoupon() {
    setState(() {
      _coupon = null;
      _couponError = null;
      _couponController.clear();
    });
  }

  Future<void> _checkCoupon() async {
    final code = _couponController.text.trim();    if (code.isEmpty) {
      // 空输入点验证 → 视为清除已应用的券（也给提示）。
      setState(() {
        _coupon = null;
        _couponError = '请输入优惠码';
      });
      return;
    }
    setState(() {
      _checkingCoupon = true;
      _couponError = null;
      // 重新验证即作废上一张已应用的券：无论新码有效与否，旧券都不再生效
      // （修「先用有效码、再输无效码时仍显示『已应用』」的矛盾态）。
      _coupon = null;
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
          setState(() => _couponError = resolveErrorText(error, fallback: '优惠码验证失败'));
      }
    } finally {
      if (mounted) setState(() => _checkingCoupon = false);
    }
  }

  Future<void> _submitOrder() async {
    // 更换套餐确认（仅购买模式）：当前有「仍生效（未到期）」套餐且所选 ≠ 当前 → 提示会覆盖。
    // 旧套餐已到期 / 无生效套餐 / 续费 / 选的就是当前套餐 → 视为正常下单，不打扰。
    if (!widget.renew) {
      final sub = ref.read(userProfileProvider).value;
      if (_shouldConfirmSwitch(sub)) {
        final ok = await _confirmSwitchPlan(sub!);
        if (!ok || !mounted) return;
      }
    }
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
            brandColor: xbBrandColor(),
            replace: true,
          );
        case XbFailure(:final error):
          _toast('提交订单失败：${resolveErrorText(error, fallback: "请稍后重试")}');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 是否需弹「更换套餐」确认：当前有生效（未到期）套餐 + 所选套餐 ≠ 当前套餐。
  /// expiredAt==null = 长期有效（视为生效）；expiredAt 在未来 = 仍生效；已过去 = 已到期（不提示）。
  bool _shouldConfirmSwitch(XbDomainSubscription? sub) =>
      shouldConfirmPlanSwitch(
        current: sub,
        newPlanId: plan.id,
        isRenew: widget.renew,
        now: DateTime.now(),
      );

  /// 更换套餐确认弹窗（原型 16b）：警示徽标 + 覆盖说明 + 当前→新套餐对比 + 品牌确认键（非破坏性）。
  Future<bool> _confirmSwitchPlan(XbDomainSubscription sub) async {
    final ok = await xbShowDialog<bool>(
      context: context,
      brandColor: xbBrandColor(),
      builder: (ctx) => _SwitchPlanDialog(
        currentName: sub.planName ?? '当前套餐',
        newName: plan.name,
      ),
    );
    return ok ?? false;
  }

  void _toast(String msg) {
    if (!mounted) return;
    xbToast(context, msg);
  }
}

/// 更换套餐确认弹窗（原型 16b）：顶部琥珀警示圆徽标 + 覆盖说明 + 「当前 → 新套餐」对比条 +
/// 再想想/确认更换。确认键品牌色（非破坏性 —— 正常购买操作，只提醒会覆盖）。
class _SwitchPlanDialog extends StatelessWidget {
  const _SwitchPlanDialog({required this.currentName, required this.newName});

  final String currentName;
  final String newName;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 琥珀警示圆徽标（swap 图标，与其它圆形徽标一套语言）。
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: XbTokens.warn.withValues(alpha: 0.15),
            ),
            child: const Icon(Icons.swap_horiz_rounded,
                size: 26, color: XbTokens.warn),
          ),
          const SizedBox(height: 14),
          const Text('确认更换套餐？',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(
              style: TextStyle(fontSize: 13, height: 1.5, color: t.onv),
              children: [
                const TextSpan(text: '你当前有正在使用的套餐，购买不同套餐将'),
                TextSpan(
                    text: '覆盖现有套餐',
                    style: TextStyle(
                        color: t.on, fontWeight: FontWeight.w600)),
                const TextSpan(text: '，原套餐的剩余流量与有效期不再保留。'),
              ],
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          // 当前 → 新套餐对比条。
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: t.sfc,
              borderRadius: BorderRadius.circular(XbTokens.rMd),
              border: Border.all(color: t.line),
            ),
            child: Row(
              children: [
                _SwapCol(label: '当前', name: currentName, color: t.on, labelColor: t.onv),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(Icons.arrow_forward_rounded,
                      size: 20, color: t.onv),
                ),
                _SwapCol(
                    label: '更换为',
                    name: newName,
                    color: scheme.primary,
                    labelColor: scheme.primary),
              ],
            ),
          ),
        ],
      ),
      // 两按钮等宽对称：「再想想」用浅灰填充按钮（明显可点，不再是低对比纯文字），
      // 「确认更换」品牌实心。避免纯 TextButton 挨着实心按钮时显得很弱。
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 46,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: FilledButton.styleFrom(
                    backgroundColor: t.sfc,
                    foregroundColor: t.on,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(XbTokens.rMd)),
                  ),
                  child: const Text('再想想'),
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: SizedBox(
                height: 46,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(XbTokens.rMd)),
                  ),
                  child: const Text('确认更换'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 对比条单列（标签 + 套餐名，居中，过长省略）。
class _SwapCol extends StatelessWidget {
  const _SwapCol({
    required this.label,
    required this.name,
    required this.color,
    required this.labelColor,
  });

  final String label;
  final String name;
  final Color color;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: labelColor)),
          const SizedBox(height: 3),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}
