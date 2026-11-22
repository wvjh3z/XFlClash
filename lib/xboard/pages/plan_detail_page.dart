/// R8 套餐购买/续费页：选周期、看套餐详情、手动提交，可选优惠码。
///
/// **数据源**：`PlanItem`（列表页传入）+ 反腐层优惠券与安全下单能力。
/// 提交订单成功 → 跳 [OrderPaymentPage]（选支付方式 + 立即支付）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor, XbStateToast;
import '../widgets/xb_theme.dart' show xbPush, xbShowDialog, XbTokens;
import '../models/plan_item.dart';
import '../models/xb_domain_subscription.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../models/xb_domain_error.dart';
import 'order_list_page.dart';
import '../providers/auth_state_provider.dart';
import '../providers/xboard_providers.dart';
import '../sdk/xboard_service.dart';
import '../services/confirmed_order.dart';
import '../services/sentry_bootstrap.dart';
import '../shell/widgets/xb_responsive.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../widgets/xb_html_contrast.dart';
import '../util/period_label.dart';
import '../widgets/xb_ui_kit.dart';
import '../widgets/xb_emoji_text.dart';
import '../widgets/xb_plan_details.dart';
import 'order_payment_page.dart';
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

  Future<void> _reload() async {
    if (!mounted) return;
    final request = _load();
    setState(() {
      _retrying = true;
      _future = request;
    });
    try {
      await request;
    } catch (_) {
      // FutureBuilder retains the original error for the page's retry UI.
      // This completion Future only drives refresh state; it must not leak it.
    } finally {
      if (mounted && identical(_future, request)) {
        setState(() => _retrying = false);
      }
    }
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
          final current = plans.where((p) => p.id == widget.planId).firstOrNull;
          return current != null && current.renewable
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
  const PlanDetailPage({
    super.key,
    required this.plan,
    this.renew = false,
    this.initialPeriod,
    this.confirmedFor,
  });

  final PlanItem plan;

  /// 续费模式（原型图 13）：锁定当前套餐只选周期，标题/文案/按钮换续费语义,
  /// 周期卡显示基于月付单价的折扣（套餐无月付则不显示折扣）。
  final bool renew;

  /// 商店已选的报价。指定周期不可购买时不能悄悄改选其他报价。
  final XbPlanPeriod? initialPeriod;

  /// 已在商店确认影响的原活动套餐 ID，不是目标套餐 ID。
  final int? confirmedFor;

  @override
  ConsumerState<PlanDetailPage> createState() => _PlanDetailPageState();
}

class _PlanDetailPageState extends ConsumerState<PlanDetailPage> {
  PricePlan? _selection;
  PricePlan get _selected => _selection!;
  int _couponGeneration = 0;
  String _couponText = '';
  final _couponController = TextEditingController();
  CouponInfo? _coupon; // 已校验通过的券
  String? _couponError;
  bool _checkingCoupon = false;
  bool _submitting = false;
  XboardService? _ownerService;
  late final int _ownerRevision;

  PlanItem get plan => widget.plan;

  bool get _ownerCurrent =>
      mounted &&
      _ownerService != null &&
      ref.read(authStateProvider) == AuthState.authenticated &&
      ref.read(authStateProvider.notifier).sessionRevision == _ownerRevision &&
      identical(ref.read(xboardServiceProvider), _ownerService);

  /// 月付单价（分）—— 套餐无月付则不计算周期折扣。
  int? get _monthlyUnitCents {
    for (final p in plan.prices) {
      if (p.period == XbPlanPeriod.monthly) return orderQuoteCents(p.amountYuan);
    }
    return null;
  }

  /// 某周期相对月付的折扣百分比（省 N%）；无月付基数 / 非按月周期 / 无优惠 → null。
  int? _discountPercent(PricePlan p) {
    final monthly = _monthlyUnitCents;
    if (monthly == null || monthly <= 0) return null;
    final months = planPeriodMonths(p.period);
    if (months == null || months <= 1) return null; // 月付本身不标
    final full = monthly * months;
    if (full <= 0) return null;
    final save = (100 * (full - orderQuoteCents(p.amountYuan)!) / full).round();
    return save > 0 ? save : null;
  }

  /// 可购买周期（排除流量重置包 resetTraffic —— 重置包从首页流量提醒进入购买，不在下单页选）。
  List<PricePlan> get _purchasablePrices =>
      plan.prices
          .where(
            (p) =>
                p.period != XbPlanPeriod.resetTraffic &&
                orderQuoteCents(p.amountYuan) != null &&
                p.amountYuan > 0,
          )
          .toList()
        ..sort((a, b) => a.period.index.compareTo(b.period.index));

  @override
  void initState() {
    super.initState();
    _ownerRevision = ref.read(authStateProvider.notifier).sessionRevision;
    if (ref.read(authStateProvider) == AuthState.authenticated) {
      _ownerService = ref.read(xboardServiceProvider);
    }
    _selection = _initialSelection();
    _couponController.addListener(_onCouponTextChanged);
  }

  PricePlan? _initialSelection() {
    final prices = _purchasablePrices;
    final requested = widget.initialPeriod;
    if (requested != null) {
      return prices.where((p) => p.period == requested).firstOrNull;
    }
    return prices.where((p) => p.period == XbPlanPeriod.yearly).firstOrNull ??
        prices.firstOrNull;
  }

  @override
  void didUpdateWidget(covariant PlanDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.plan != plan ||
        oldWidget.initialPeriod != widget.initialPeriod ||
        oldWidget.confirmedFor != widget.confirmedFor) {
      _selection = _initialSelection();
      _invalidateCoupon();
    }
  }

  void _onCouponTextChanged() {
    final text = _couponController.text;
    if (text == _couponText) return;
    _couponText = text;
    _invalidateCoupon();
  }

  void _invalidateCoupon() {
    _couponGeneration++;
    setState(() {
      _coupon = null;
      _couponError = null;
      _checkingCoupon = false;
    });
  }

  @override
  void dispose() {
    _couponGeneration++;
    _couponController.removeListener(_onCouponTextChanged);
    _couponController.dispose();
    super.dispose();
  }

  int get _subtotalCents => orderQuoteCents(_selected.amountYuan)!;

  /// Integer-cent estimate only; the panel may apply account credits and
  /// discounts or round the coupon differently when it creates the order.
  int get _discountCents {
    final c = _coupon;
    if (c == null) return 0;
    final estimate =
        c.discountAmountCents ??
        switch (c.type) {
          1 => c.value,
          2 => _subtotalCents * c.value ~/ 100,
          _ => 0,
        };
    return estimate.clamp(0, _subtotalCents);
  }

  int get _estimatedCents => _subtotalCents - _discountCents;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStateProvider);
    if (_ownerService != null && auth == AuthState.authenticated) {
      ref.watch(xboardServiceProvider);
    }
    final title = widget.renew ? '续费当前套餐' : '购买套餐';
    if (_ownerService != null && !_ownerCurrent) {
      return XbBrandScaffold(
        title: title,
        body: const Center(child: Text('账号状态已变化，请返回后重新打开结算。')),
      );
    }
    if (_selection == null) {
      return XbBrandScaffold(
        title: title,
        body: Center(
          child: Text(
            widget.initialPeriod == null
                ? '暂无可购买周期，请选择其他套餐或联系客服'
                : '所选周期已不可购买，请返回重选。',
          ),
        ),
      );
    }
    final wide = xbIsDesktopWidth(MediaQuery.sizeOf(context).width);
    return XbBrandScaffold(
      title: title,
      maxContentWidth: wide ? 1000 : null,
      body: Builder(
        builder: (context) =>
            wide ? _desktopBody(context) : _mobileBody(context),
      ),
    );
  }

  List<Widget> _reviewChildren(BuildContext context) => [
    _checkoutActions(context, showBack: false),
    const SizedBox(height: 14),
    XbSectionCard(title: '优惠码', child: _couponSection(context)),
  ];

  Widget _mobileBody(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _planDetails(context),
          const SizedBox(height: 11),
          XbSectionCard(
            title: widget.renew ? '选择续费时长' : '选择计费周期',
            child: _periodSection(context, mobile: true),
          ),
          const SizedBox(height: 11),

          _checkoutActions(context),
          const SizedBox(height: 12),
          XbSectionCard(
            title: '优惠码',
            child: _couponSection(context),
          ),
        ],
      ),
    );
  }

  Widget _checkoutActions(BuildContext context, {bool showBack = true}) {
    final theme = Theme.of(context);
    final t = XbTokens.of(context);
    final brand = theme.colorScheme.primary;
    final enabled = !_checkingCoupon && !_submitting;
    var gradientStart = Color.lerp(brand, Colors.white, 0.16)!;
    // Preserve at least 4.66:1 against white, including the bright end.
    while (gradientStart.computeLuminance() > 0.175) {
      gradientStart = Color.lerp(gradientStart, Colors.black, 0.05)!;
    }
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(XbTokens.rButton),
    );
    ButtonStyle actionStyle(Color fill, Color foreground) =>
        FilledButton.styleFrom(
          backgroundColor: fill,
          disabledBackgroundColor: t.sfc,
          foregroundColor: foreground,
          disabledForegroundColor: t.onv,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          shape: shape,
          textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
          elevation: 0,
        );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showBack) ...[
            SizedBox(
              width: 96,
              child: FilledButton(
                onPressed: _submitting ? null : () => Navigator.maybePop(context),
                style: actionStyle(t.sfc, t.on),
                child: const Text('返回', textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: shape.borderRadius,
                gradient: enabled
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          gradientStart,
                          Color.lerp(gradientStart, Colors.black, 0.24)!,
                        ],
                      )
                    : null,
              ),
              child: FilledButton(
                onPressed: enabled ? _submitOrder : null,
                style: actionStyle(Colors.transparent, Colors.white),
                child: _submitting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.shopping_cart_checkout_rounded,
                            size: 19,
                            color: enabled ? Colors.white : t.onv,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              widget.renew ? '确认续费' : '提交订单',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: enabled ? Colors.white : t.onv,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 桌面保留双栏：上方完整展示套餐内容，下方左选周期、右侧提交。
  Widget _desktopBody(BuildContext context) {
    final periodCard = XbSectionCard(
      title: widget.renew ? '选择续费时长' : '选择计费周期',
      child: _periodSection(context, columns: 3),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 11,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_planDetails(context), const SizedBox(height: 14), periodCard],
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                flex: 9,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _reviewChildren(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _planDetails(BuildContext context) => XbCard(
    radius: XbTokens.rLg,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: XbEmojiText(
            plan.name,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        XbPlanDetails(plan: plan),
      ],
    ),
  );

  Widget _periodSection(
    BuildContext context, {
    int columns = 2,
    bool mobile = false,
  }) {
    final sorted = _purchasablePrices;
    // 显式网格（不用 Wrap——Wrap 行高内容驱动、与原型 grid 难对齐）：每行 [columns] 个
    // Expanded 严格等宽；末行不足补等宽空占位保持卡宽一致。桌面 3 列（原型 .pgrid），移动 2 列。
    final gap = mobile ? 8.0 : 10.0;
    final rowGap = mobile ? 8.0 : 12.0;
    final rows = <Widget>[];
    for (var i = 0; i < sorted.length; i += columns) {
      final cells = <Widget>[];
      for (var c = 0; c < columns; c++) {
        final idx = i + c;
        if (c > 0) cells.add(SizedBox(width: gap));
        cells.add(
          Expanded(
            child: idx < sorted.length
                ? _periodCard(context, sorted[idx], mobile: mobile)
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
      );
      if (i + columns < sorted.length) rows.add(SizedBox(height: rowGap));
    }
    return Column(children: rows);
  }

  Widget _periodCard(BuildContext context, PricePlan p, {required bool mobile}) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = p.period == _selected.period;
    // 基于月付单价算折扣「省 N%」（套餐无月付/无优惠则不显示）；购买、续费两模式都显示。
    final savePct = _discountPercent(p);
    final textScaler = MediaQuery.textScalerOf(context);
    final largeMobileText = mobile && textScaler.scale(14) > 21;
    final selectedInk = mobile
        ? _mobileBrandInk(
            scheme.primary,
            Color.alphaBlend(scheme.primary.withValues(alpha: 0.07), t.card),
            t.on,
          )
        : scheme.primary;
    final periodLabel = Text(
      planPeriodLabel(p.period),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13.5,
        color: selected ? selectedInk : t.on,
        fontWeight: FontWeight.w500,
      ),
    );
    final discount = savePct == null
        ? null
        : Text(
            '省 $savePct%',
            style: TextStyle(
              fontSize: 11,
              color: selected ? selectedInk : t.onv,
            ),
          );
    return XbSelectableOption(
      selected: selected,
      compact: true,
      onTap: () {
        if (_submitting || selected) return;
        _invalidateCoupon();
        setState(() {
          _selection = p;
          // 周期变 → 已校验的券失效（券与周期绑定，需重校验）。
          _coupon = null;
          _couponError = null;
        });
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (largeMobileText) ...[
            periodLabel,
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: SizedBox(
                height: textScaler.scale(11) * 1.4,
                child: discount,
              ),
            ),
          ] else
            Row(
              children: [
                Expanded(child: periodLabel),
                ?discount,
              ],
            ),
          const SizedBox(height: 4),
          // 价格恒为一行（长价格如 ¥142.50 在半宽卡里若换行 → 行高比短价格多 26px、整行变形，
          // 已被 plan_period_grid_test 尺寸断言锁定）。固定行高 26 + XbFitText 仅在放不下时等比缩，
          // 不换行；固定高消除「短价格不缩/长价格缩」的亚像素行高差，所有卡严格等高。
          SizedBox(
            height: largeMobileText ? textScaler.scale(18) * 1.4 : 26,
            child: XbFitText(
              xbYuan(p.amountYuan),
              alignment: Alignment.centerLeft,
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 18,
                color: selected ? selectedInk : t.on,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _couponSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = XbTokens.of(context);
    final appliedInk = _mobileBrandInk(scheme.primary, t.card, t.on);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _couponRow(context),
        if (_coupon != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 16, color: appliedInk),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '优惠券已应用',
                  style: text.bodySmall?.copyWith(color: appliedInk),
                ),
              ),
              // 取消已应用的优惠券（清空券 + 输入框 + 错误）。
              GestureDetector(
                onTap: _clearCoupon,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    '取消',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _couponRow(BuildContext context) {
    final theme = Theme.of(context);
    final t = XbTokens.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme.bodyMedium;
    final fontSize = text?.fontSize ?? 14;
    final height =
        44 + MediaQuery.textScalerOf(context).scale(fontSize) - fontSize;
    final enabled = !_checkingCoupon && !_submitting;
    final verifyFill = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.10),
      t.card,
    );
    final verifyInk = _mobileBrandInk(scheme.primary, verifyFill, t.on);
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(XbTokens.rSm),
      borderSide: BorderSide(color: color, width: width),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: height,
                child: TextField(
                  controller: _couponController,
                  enabled: enabled,
                  textAlignVertical: TextAlignVertical.center,
                  style: text,
                  decoration: InputDecoration(
                    hintText: '输入优惠码（如有）',
                    isDense: true,
                    constraints: BoxConstraints.tightFor(height: height),
                    filled: true,
                    fillColor: t.sf2,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                    border: border(t.line, 1.5),
                    disabledBorder: border(t.line, 1.5),
                    enabledBorder: _couponError == null
                        ? border(t.line, 1.5)
                        : border(scheme.error, 1.5),
                    focusedBorder: _couponError == null
                        ? border(scheme.primary, 1.8)
                        : border(scheme.error, 1.8),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: enabled ? _checkCoupon : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: verifyInk,
                backgroundColor: verifyFill,
                side: BorderSide(
                  color: Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.30),
                    t.line,
                  ),
                  width: 1.5,
                ),
                minimumSize: Size(0, height),
                padding: const EdgeInsets.symmetric(horizontal: 15),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(XbTokens.rSm),
                ),
              ),
              child: _checkingCoupon
                  ? _couponSpinner(verifyInk)
                  : const Text('验证'),
            ),
          ],
        ),
        if (_couponError case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          ),
      ],
    );
  }

  Widget _couponSpinner(Color color) => SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2, color: color),
  );

  Color _mobileBrandInk(Color brand, Color background, Color on) {
    var ink = brand;
    for (var i = 0; i < 16; i++) {
      if (xbHtmlContrastRatio(ink, background) >= 4.6) return ink;
      ink = Color.lerp(ink, on, 0.14)!;
    }
    return on;
  }

  /// 取消已应用的优惠券：清空券、输入框和错误，提交预估恢复原价。
  void _clearCoupon() {
    if (_submitting) return;
    _invalidateCoupon();
    setState(() {
      _coupon = null;
      _couponError = null;
      _couponController.clear();
    });
  }

  Future<void> _checkCoupon() async {
    if (_selection == null || _submitting || _checkingCoupon) return;
    if (!_ownerCurrent) {
      setState(() => _couponError = '账号状态已变化，请登录后重新进入结算。');
      return;
    }
    final generation = ++_couponGeneration;
    final period = _selected.period;
    final planId = plan.id;
    final code = _couponController.text.trim();
    if (code.isEmpty) {
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
      final result = await _ownerService!.checkCoupon(code, planId, period);
      if (!_ownerCurrent ||
          generation != _couponGeneration ||
          plan.id != planId ||
          _selection?.period != period ||
          _couponController.text.trim() != code) {
        return;
      }
      switch (result) {
        case XbSuccess(:final data):
          if (data == null ||
              data.code.isEmpty ||
              (data.type != 1 && data.type != 2) ||
              data.value < 0 ||
              (data.type == 2 && data.value > 100) ||
              (data.endedAt != null &&
                  !data.endedAt!.isAfter(DateTime.now()))) {
            setState(() => _couponError = '优惠码无效');
          } else {
            setState(() => _coupon = data);
          }
        case XbFailure(:final error):
          setState(
            () => _couponError = resolveErrorText(error, fallback: '优惠码验证失败'),
          );
      }
    } catch (error, stack) {
      if (_ownerCurrent && generation == _couponGeneration) {
        SentryBootstrap.captureException(
          error,
          stackTrace: stack,
          where: 'check coupon',
        );
        setState(() => _couponError = '优惠码验证失败');
      }
    } finally {
      if (mounted && generation == _couponGeneration) {
        setState(() => _checkingCoupon = false);
      }
    }
  }

  Future<void> _submitOrder() async {
    if (!mounted || _submitting || _checkingCoupon || _selection == null) return;
    if (!_ownerCurrent) {
      xbToastSafe('账号状态已变化，请登录后重新进入结算。');
      return;
    }
    final service = _ownerService!;
    final submittedPlan = plan;
    final selection = _selected;
    final estimate = _estimatedCents;
    final catalogCents = _subtotalCents;
    final coupon = _coupon;
    final couponGeneration = _couponGeneration;
    final confirmedFor = widget.confirmedFor;
    final renew = widget.renew;
    final route = ModalRoute.of(context);
    bool current() =>
        _ownerCurrent &&
        (route?.isActive ?? true) &&
        plan == submittedPlan &&
        _selection == selection &&
        _couponGeneration == couponGeneration &&
        widget.confirmedFor == confirmedFor &&
        widget.renew == renew;
    if (coupon?.endedAt case final expiry?
        when !expiry.isAfter(DateTime.now())) {
      _invalidateCoupon();
      xbToastSafe('优惠码已过期，请重新验证。');
      return;
    }
    setState(() => _submitting = true);
    try {
      final subscriptionRead = await service.getSubscription();
      if (!current()) return;
      if (subscriptionRead case XbFailure<XbDomainSubscription>(:final error)) {
        xbToastSafe(
          '无法核对当前套餐：${resolveErrorText(error, fallback: '请稍后重试')}',
        );
        return;
      }
      final sub = subscriptionRead.dataOrNull!;
      final subscription = ConfirmedOrderSubscription(
        planId: sub.planId,
        totalBytes: sub.totalBytes,
        expiredAt: sub.expiredAt,
      );
      final activeId = subscription.activePlanId;
      if (activeId != null && activeId != confirmedFor) {
        final switchPlan = shouldConfirmPlanSwitch(
          current: sub,
          newPlanId: submittedPlan.id,
          isRenew: false,
          now: DateTime.now(),
        );
        // Older renewal callers already enter through a dedicated renewal
        // route; the store passes its explicit confirmation instead.
        if (switchPlan || !renew) {
          final accepted = await _confirmPlanImpact(
            sub,
            same: activeId == submittedPlan.id,
          );
          if (!accepted || !current()) return;
        }
      }
      if (!mounted || !current()) return;
      final result = await submitConfirmedOrder(
        context: context,
        service: service,
        isActive: current,
        quote: ConfirmedOrderQuote(
          planId: submittedPlan.id,
          planName: submittedPlan.name,
          period: selection.period,
          estimatedCents: estimate,
          catalogCents: catalogCents,
          couponCode: coupon?.code,
          couponEndsAt: coupon?.endedAt,
          expectedSubscription: subscription,
        ),
      );
      if (!mounted || !current()) return;
      switch (result) {
        case XbSuccess(:final data):
          if (data == null) return;
          // 跳支付页（订单号），返回时回退到列表。
          unawaited(
            xbPush(
              context,
              OrderPaymentPage(tradeNo: data),
              brandColor: xbBrandColor(),
              replace: true,
            ),
          );
        case XbFailure(:final error):
          if (error is XbUnconfirmed) {
            xbToastSafe(resolveErrorText(error));
            if (mounted) {
              unawaited(
                xbPush(
                  context,
                  const OrderListPage(),
                  brandColor: xbBrandColor(),
                  replace: true,
                ),
              );
            }
            return;
          }
          xbToastSafe(
            '提交订单失败：${resolveErrorText(error, fallback: "请稍后重试")}',
          );
      }
    } catch (error, stack) {
      if (current()) {
        SentryBootstrap.captureException(
          error,
          stackTrace: stack,
          where: 'prepare plan order',
        );
        xbToastSafe('无法核对当前套餐，请稍后重试。');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Backstop for older callers or a subscription that changed after the store.
  Future<bool> _confirmPlanImpact(
    XbDomainSubscription sub, {
    required bool same,
  }) async {
    final ok = await xbShowDialog<bool>(
      context: context,
      brandColor: xbBrandColor(),
      builder: (ctx) => same
          ? AlertDialog(
              title: const Text('确认续费当前套餐？'),
              content: const Text('续费将延长有效期，已用流量和重置日不变。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('再想想'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('确认续费'),
                ),
              ],
            )
          : _SwitchPlanDialog(
              currentName: sub.planName ?? '当前套餐',
              newName: plan.name,
            ),
    );
    return ok ?? false;
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
    return AlertDialog(
      title: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '确认更换套餐？',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 13, height: 1.5, color: t.onv),
                children: [
                  const TextSpan(text: '你当前有正在使用的套餐，购买不同套餐将'),
                  TextSpan(
                    text: '覆盖现有套餐',
                    style: TextStyle(color: t.on, fontWeight: FontWeight.w600),
                  ),
                  const TextSpan(text: '，原套餐的剩余流量与有效期不再保留。'),
                ],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            XbPlanComparison(current: currentName, target: newName),
          ],
        ),
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
                      borderRadius: BorderRadius.circular(XbTokens.rMd),
                    ),
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
                      borderRadius: BorderRadius.circular(XbTokens.rMd),
                    ),
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
