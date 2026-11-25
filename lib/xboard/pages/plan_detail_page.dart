/// R8 套餐购买/续费页：选周期、看套餐详情、手动提交，可选优惠码。
///
/// **数据源**：`PlanItem`（列表页传入）+ 反腐层优惠券与安全下单能力。
/// 提交订单成功 → 跳 [OrderPaymentPage]（选支付方式 + 立即支付）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/xb_async_view.dart';
import '../widgets/xb_network_read_recovery.dart';
import '../providers/xboard_connectivity_provider.dart';
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
import '../widgets/xb_purchase_confirmation.dart';
import 'order_payment_page.dart';
import 'plan_list_page.dart';
import 'commerce_read_recovery.dart';

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
class PlanRenewLoader extends ConsumerWidget {
  const PlanRenewLoader({super.key, required this.planId});

  final int planId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authStateProvider);
    final owner = (auth, ref.read(authStateProvider.notifier).sessionRevision, ref.watch(xboardServiceProvider), planId);
    return _OwnedRenewLoader(key: ValueKey(owner), planId: planId,
      current: () => ref.read(authStateProvider) == owner.$1 &&
        ref.read(authStateProvider.notifier).sessionRevision == owner.$2 && identical(ref.read(xboardServiceProvider), owner.$3));
  }
}

class _OwnedRenewLoader extends ConsumerStatefulWidget {
  const _OwnedRenewLoader({super.key, required this.planId, required this.current});
  final int planId;
  final bool Function() current;
  @override
  ConsumerState<_OwnedRenewLoader> createState() => _PlanRenewLoaderState();
}

class _PlanRenewLoaderState extends ConsumerState<_OwnedRenewLoader> {
  late Future<List<PlanItem>> _future;
  bool _retrying = false;
  Object? _lastError;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<PlanItem>> _load() async {
    _lastError = null;
    final result = ref.read(isOfflineProvider)
        ? const XbFailure<List<PlanItem>>(XbNetwork(XbNetworkKind.connectionFailed, '当前离线'))
        : await ref.read(xboardServiceProvider).getPlans();
    _lastError = result.errorOrNull;
    return switch (result) {
      XbSuccess(:final data) => data,
      XbFailure(:final error) => throw error,
    };
  }

  Future<void> _reload() async {
    if (!mounted || _retrying) return;
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
    xbListenForReadRecovery(context, ref, () {
      if (_retrying) return;
      recoverCommerceRead(context: context, current: () => mounted && widget.current(), pending: _future,
        retryIfFailed: () async {
          if (!_retrying && xbIsRecoverableReadError(_lastError)) await _reload();
        });
    });
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
              : PlanListPage(initialPlans: plans);
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
  final _couponFocus = FocusNode();
  CouponInfo? _coupon; // 已校验通过的券
  String? _couponError;
  Object? _couponReadFailure;
  bool _checkingCoupon = false;
  bool _submitting = false;
  String _orderStage = '正在核对当前套餐';
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
    _couponReadFailure = null;
    setState(() {
      _coupon = null;
      _couponError = null;
      _checkingCoupon = false;
    });
  }

  @override
  void dispose() {
    _couponFocus.dispose();
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
    ref.watch(isOfflineProvider);
    xbListenForReadRecovery(context, ref, () {
      if (_ownerCurrent && !_submitting && !_checkingCoupon &&
          xbIsRecoverableReadError(_couponReadFailure)) {
        _checkCoupon();
      }
    });
    final auth = ref.watch(authStateProvider);
    if (_ownerService != null && auth == AuthState.authenticated) {
      ref.watch(xboardServiceProvider);
    }
    final wide = xbIsDesktopWidth(MediaQuery.sizeOf(context).width);
    final title = widget.renew ? '续费当前套餐' : wide ? '购买套餐' : plan.name;
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
    _checkoutActions(context),
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

  Widget _checkoutActions(BuildContext context) {
    final theme = Theme.of(context);
    final t = XbTokens.of(context);
    final enabled = !_checkingCoupon && !_submitting && !ref.read(isOfflineProvider);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(XbTokens.rButton),
    );
    final backColor = theme.brightness == Brightness.dark
        ? Color.lerp(theme.colorScheme.primary, t.on, .4)!
        : theme.colorScheme.primary;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
            SizedBox(
              width: 72,
              child: OutlinedButton(
                onPressed: _submitting ? null : () => Navigator.maybePop(context),
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.transparent, foregroundColor: backColor,
                  disabledForegroundColor: t.onv, minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8), shape: shape,
                  side: BorderSide(color: _submitting ? t.line : Color.lerp(t.line, backColor, .32)!, width: 1.5),
                  textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                child: const Text('返回', textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 10),
          Expanded(
            child: XbGradientAction(
              onPressed: enabled ? _submitOrder : null,
              busyLabel: _submitting ? _orderStage : null,
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shopping_cart_checkout_rounded, size: 19,
                      color: enabled ? Colors.white : t.onv),
                  const SizedBox(width: 6),
                  Flexible(child: Text(
                    widget.renew ? '确认续费' : '提交订单',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: enabled ? Colors.white : t.onv, fontSize: 15, fontWeight: FontWeight.w700),
                  )),
                ],
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
      child: _periodSection(context),
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
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: XbEmojiText(
            plan.name,
            style: xbPlanTitleStyle(Theme.of(context)),
          ),
        ),
        XbPlanDetails(plan: plan, showQuota: false, compact: true, tightDescription: true),
      ],
    ),
  );

  Widget _periodSection(
    BuildContext context, {
    bool mobile = false,
  }) {
    const columns = 3;
    final sorted = _purchasablePrices;
    // 显式网格（不用 Wrap——Wrap 行高内容驱动、与原型 grid 难对齐）：每行 [columns] 个
    // Expanded 严格等宽；末行不足补等宽空占位保持卡宽一致。桌面和移动均为三列。
    const gap = 6.0;
    const rowGap = 4.0;
    final rows = <Widget>[];
    for (var i = 0; i < sorted.length; i += columns) {
      final cells = <Widget>[];
      for (var c = 0; c < columns; c++) {
        final idx = i + c;
        if (c > 0) cells.add(const SizedBox(width: gap));
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
      if (i + columns < sorted.length) rows.add(const SizedBox(height: rowGap));
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
    final selectedInk = _mobileBrandInk(
            scheme.primary,
            Color.alphaBlend(scheme.primary.withValues(alpha: 0.07), t.card),
            t.on,
          );
    final periodLabel = Text(
      planPeriodLabel(p.period),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: mobile ? 13 : 16,
        color: selected ? selectedInk : t.on,
        fontWeight: FontWeight.w500,
      ),
    );
    return XbSelectableOption(
      insetTag: !mobile,
      selected: selected,
      tag: savePct == null ? null : '省 $savePct%',
      tagColor: _mobileBrandInk(scheme.primary, Colors.white, Colors.black),
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: periodLabel),
          const SizedBox(height: 1),
          // 价格恒为一行（长价格如 ¥142.50 在半宽卡里若换行 → 行高比短价格多 26px、整行变形，
          // 已被 plan_period_grid_test 尺寸断言锁定）。固定行高 26 + XbFitText 仅在放不下时等比缩，
          // 不换行；固定高消除「短价格不缩/长价格缩」的亚像素行高差，所有卡严格等高。
          SizedBox(
            height: !mobile ? textScaler.scale(18) * 1.5 :
                largeMobileText ? textScaler.scale(16) * 1.4 : 22,
            child: XbFitText(
              xbYuan(p.amountYuan),
              alignment: Alignment.center,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: mobile ? 16 : 18,
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
    final text = theme.textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.45);
    final lineHeight = MediaQuery.textScalerOf(context).scale(14) * 1.45;
    final height = (lineHeight + 18).clamp(44.0, double.infinity).toDouble();
    final enabled = !_checkingCoupon && !_submitting;
    final verifyFill = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.10),
      t.card,
    );
    final verifyInk = _mobileBrandInk(scheme.primary, verifyFill, t.on);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntrinsicHeight(child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: _couponFocus,
                builder: (_, child) => Container(
                  key: const ValueKey('coupon-input-surface'),
                  constraints: BoxConstraints(minHeight: height),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  decoration: BoxDecoration(
                    color: t.sf2,
                    borderRadius: BorderRadius.circular(XbTokens.rSm),
                    border: Border.all(
                      color: _couponError != null ? scheme.error : _couponFocus.hasFocus ? scheme.primary : t.line,
                      width: _couponFocus.hasFocus ? 2 : 1,
                    ),
                  ),
                  child: child,
                ),
                child: TextField(
                  controller: _couponController,
                  focusNode: _couponFocus,
                  enabled: enabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _checkCoupon(),
                  minLines: 1,
                  maxLines: null,
                  maxLength: 64,
                  textAlignVertical: TextAlignVertical.center,
                  style: text,
                  decoration: InputDecoration(
                    isCollapsed: true, isDense: true, filled: false,
                    contentPadding: EdgeInsets.zero, counterText: '',
                    border: InputBorder.none, focusedBorder: InputBorder.none,
                    enabledBorder: InputBorder.none, disabledBorder: InputBorder.none,
                    hintText: '输入优惠码（如有）',
                    hintStyle: text?.copyWith(color: t.onv),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: MediaQuery.textScalerOf(context).scale(14) * 2 + 32,
              child: OutlinedButton(
              onPressed: enabled ? _checkCoupon : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: verifyInk,
                backgroundColor: verifyFill,
                side: BorderSide(
                  color: Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.30),
                    t.line,
                  ),
                  width: 1,
                ),
                minimumSize: Size(0, height),
                textStyle: text?.copyWith(fontWeight: FontWeight.w600),
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(XbTokens.rSm),
                ),
              ),
              child: Text(_checkingCoupon ? '正在验证…' : '验证',
                textAlign: TextAlign.center, softWrap: true),
              ),
            ),
          ],
        )),
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
    _couponReadFailure = null;
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
      final result = ref.read(isOfflineProvider)
          ? const XbFailure<CouponInfo?>(XbNetwork(XbNetworkKind.connectionFailed, '当前离线'))
          : await _ownerService!.checkCoupon(code, planId, period);
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
          _couponReadFailure = error;
          setState(
            () => _couponError = resolveErrorText(error, fallback: '优惠码验证失败'),
          );
      }
    } catch (error, stack) {
      if (_ownerCurrent && generation == _couponGeneration) {
        _couponReadFailure = error;
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
    if (!mounted || _submitting || _checkingCoupon || _selection == null || ref.read(isOfflineProvider)) return;
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
    setState(() {
      _orderStage = '正在核对当前套餐…';
      _submitting = true;
    });
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
      setState(() => _orderStage = '正在核对订单…');
      final result = await submitConfirmedOrder(
        context: context,
        service: service,
        isActive: current,
        onStage: (stage) {
          if (!mounted || !_submitting || !current()) return;
          final label = switch (stage) {
            ConfirmedOrderStage.checking => '正在核对订单…',
            ConfirmedOrderStage.awaitingConfirmation => '等待确认旧订单…',
            ConfirmedOrderStage.cancelling => '正在取消旧订单…',
            ConfirmedOrderStage.checkingCancellation => '正在核实取消结果…',
            ConfirmedOrderStage.creating || ConfirmedOrderStage.verifying => '正在创建订单…',
          };
          if (_orderStage != label) setState(() => _orderStage = label);
        },
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
      builder: (ctx) => XbPlanConfirmation(
        planName: sub.planName ?? (same ? plan.name : '当前套餐'),
        targetName: same ? null : plan.name,
        confirmLabel: same ? '确认续费' : '确认更换',
      ),
    );
    return ok ?? false;
  }
}
