/// 首页原地确认和节点缺流量页共用流量重置的真实报价、下单与恢复。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor, XbStateToast;
import '../widgets/xb_theme.dart' show xbDialogRoute, xbPush, XbTokens;
import '../models/plan_item.dart';
import '../models/xb_domain_subscription.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../models/xb_domain_error.dart';
import 'order_list_page.dart';
import '../providers/xboard_providers.dart';
import '../providers/auth_state_provider.dart';
import '../providers/user_profile_provider.dart';
import '../sdk/xboard_service.dart';
import '../services/confirmed_order.dart';
import '../services/sentry_bootstrap.dart';
import '../shell/widgets/xb_responsive.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../widgets/xb_ui_kit.dart';
import '../widgets/xb_purchase_confirmation.dart';
import 'order_payment_page.dart';

final _resetDialogs = Expando<DialogRoute<Widget>>();

void showTrafficResetDialog(
  BuildContext context,
  WidgetRef ref,
  XbDomainSubscription subscription, {
  required bool Function(XbDomainSubscription) isEligible,
}) {
  final planId = subscription.planId;
  if (planId == null) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  if (_resetDialogs[navigator]?.isActive ?? false) return;
  final owner = ref.read(xboardServiceProvider);
  final revision = ref.read(authStateProvider.notifier).sessionRevision;
  final route = xbDialogRoute<Widget>(
    context: context,
    brandColor: xbBrandColor(),
    builder: (_) => ResetTrafficPage._dialog(
      planId: planId,
      planName: subscription.planName,
      subscription: subscription,
      isEligible: isEligible,
      owner: owner,
      revision: revision,
    ),
  );
  _resetDialogs[navigator] = route;
  unawaited(
    navigator.push(route).then((destination) {
      if (destination != null && context.mounted &&
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          ref.read(authStateProvider.notifier).sessionRevision == revision &&
          identical(ref.read(xboardServiceProvider), owner)) {
        unawaited(xbPush(context, destination, brandColor: xbBrandColor()));
      }
    }).whenComplete(() {
      if (identical(_resetDialogs[navigator], route)) {
        _resetDialogs[navigator] = null;
      }
    }),
  );
}

class ResetTrafficPage extends ConsumerStatefulWidget {
  const ResetTrafficPage({super.key, required this.planId, this.planName})
    : _subscription = null,
      _isEligible = null,
      _owner = null,
      _revision = null;

  const ResetTrafficPage._dialog({
    required this.planId,
    required this.planName,
    required XbDomainSubscription subscription,
    required bool Function(XbDomainSubscription) isEligible,
    required XboardService owner,
    required int revision,
  }) : _subscription = subscription,
       _isEligible = isEligible,
       _owner = owner,
       _revision = revision;

  /// 当前套餐 id（来自 [XbDomainSubscription.planId]）。
  final int planId;

  /// 当前套餐名（仅用于展示，可空）。
  final String? planName;
  final XbDomainSubscription? _subscription;
  final bool Function(XbDomainSubscription)? _isEligible;
  final XboardService? _owner;
  final int? _revision;

  @override
  ConsumerState<ResetTrafficPage> createState() => _ResetTrafficPageState();
}

class _ResetTrafficPageState extends ConsumerState<ResetTrafficPage> {
  PlanItem? _plan;
  int? _resetCents;
  XbDomainError? _loadError; // 领域错误对象（交由 XbAsyncView 经 resolveErrorText 解析）
  bool _loading = true;
  bool _retrying = false; // 重试中 → 顶部「正在刷新服务」黄条
  bool _submitting = false;
  int _loadGeneration = 0;
  bool _closed = false;
  late final XboardService _ownerService;
  late final int _ownerRevision;
  ModalRoute<dynamic>? _route;

  bool get _inline => widget._subscription != null;

  bool _offerAvailable(XbDomainSubscription subscription, DateTime now) =>
      !_inline || (subscription.expiredAt?.isAfter(now) ?? true);

  bool get _ownerCurrent =>
      mounted &&
      !_closed &&
      (_route?.isActive ?? true) &&
      _route?.animation?.status != AnimationStatus.reverse &&
      ref.read(authStateProvider) == AuthState.authenticated &&
      ref.read(authStateProvider.notifier).sessionRevision == _ownerRevision &&
      identical(ref.read(xboardServiceProvider), _ownerService);

  XbDomainSubscription? _matchingSubscription(
    AsyncValue<XbDomainSubscription> profile,
  ) {
    final initial = widget._subscription;
    final current = profile.asData?.value;
    if (current == null ||
        profile.hasError ||
        current.planId != widget.planId ||
        current.totalBytes <= 0 ||
        current.usedBytes < 0 ||
        (initial != null &&
            (current.uuid != initial.uuid ||
                current.email != initial.email ||
                !widget._isEligible!(current)))) {
      return null;
    }
    return current;
  }

  @override
  void initState() {
    super.initState();
    _ownerService = widget._owner ?? ref.read(xboardServiceProvider);
    _ownerRevision =
        widget._revision ?? ref.read(authStateProvider.notifier).sessionRevision;
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(covariant ResetTrafficPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.planId != widget.planId) _load();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  Future<void> _load({bool retry = false}) async {
    if (!_ownerCurrent) return;
    final generation = ++_loadGeneration;
    final planId = widget.planId;
    setState(() {
      _loading = true;
      _retrying = retry;
      _loadError = null;
      _plan = null;
      _resetCents = null;
    });
    XbResult<List<PlanItem>> result;
    try {
      result = await _ownerService.getPlans();
    } catch (error, stack) {
      if (!_ownerCurrent ||
          generation != _loadGeneration ||
          planId != widget.planId) {
        return;
      }
      SentryBootstrap.captureException(
        error,
        stackTrace: stack,
        where: 'reset traffic plans',
      );
      setState(() {
        _loading = false;
        _retrying = false;
        _loadError = const XbUnexpected('getPlans', '加载失败，请重试');
      });
      return;
    }
    if (!_ownerCurrent ||
        generation != _loadGeneration ||
        planId != widget.planId) {
      return;
    }
    switch (result) {
      case XbSuccess(:final data):
        PlanItem? plan;
        for (final p in data) {
          if (p.id == planId) {
            plan = p;
            break;
          }
        }
        final resetPrices = plan?.prices
            .where((price) => price.period == XbPlanPeriod.resetTraffic)
            .toList();
        final resetCents = resetPrices != null && resetPrices.length == 1
            ? orderQuoteCents(resetPrices.single.amountYuan)
            : null;
        setState(() {
          _loadError = null;
          _plan = plan;
          _resetCents = resetCents;
          _loading = false;
          _retrying = false;
        });
      case XbFailure(:final error):
        setState(() {
          _loadError = error;
          _loading = false;
          _retrying = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(authStateProvider);
    ref.watch(xboardServiceProvider);
    final profile = _ownerCurrent ? ref.watch(userProfileProvider) : null;
    final subscription = profile == null ? null : _matchingSubscription(profile);
    final profileRefreshing = profile?.isLoading ?? false;
    if (_inline) {
      return _trackClose(
        _dialog(context, subscription, profileRefreshing: profileRefreshing),
      );
    }
    if (!_ownerCurrent) {
      return _trackClose(
        const XbBrandScaffold(
          title: '购买流量重置包',
          body: XbEmptyState(
            icon: Icons.lock_outline,
            title: '账号状态已变化',
            description: '请返回后重新打开流量重置页。',
          ),
        ),
      );
    }
    // 桌面（原型屏37）：内容单列居中限宽 560 + 提交按钮内联列底；窄屏维持固定底栏。
    final wide = xbIsDesktopWidth(MediaQuery.sizeOf(context).width);
    final VoidCallback? onSubmit = subscription == null || profileRefreshing
        ? null
        : () => _submitOrder(subscription);
    return _trackClose(
      XbBrandScaffold(
        title: '购买流量重置包',
        maxContentWidth: wide ? 560 : null,
        bottomNavigationBar: wide || onSubmit == null
            ? null
            : _bottomBar(onSubmit),
        body: XbAsyncView(
          loading: (_loading && !_retrying) || profileRefreshing,
          retrying: _retrying,
          error: _loadError ?? (profile?.hasError == true ? profile!.error : null),
          errorFallback: '加载失败',
          onRetry: () {
            if (profile?.hasError == true) ref.invalidate(userProfileProvider);
            _load(retry: true);
          },
          builder: (context) => subscription == null
              ? const XbEmptyState(
                  icon: Icons.info_outline_rounded,
                  title: '当前套餐状态已变化',
                  description: '请返回后重新打开流量重置页。',
                )
              : _resetCents == null
              ? _unavailable(context)
              : _content(
                  context,
                  subscription,
                  _plan!,
                  _resetCents!,
                  wide,
                  onSubmit,
                ),
        ),
      ),
    );
  }

  Widget _trackClose(Widget child) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _closed = true;
    },
    child: child,
  );

  void _showOrderDestination(Widget page) {
    if (widget._subscription != null) {
      _closed = true;
      Navigator.of(context).pop<Widget>(page);
    } else {
      unawaited(xbPush(context, page, brandColor: xbBrandColor(), replace: true));
    }
  }

  void _close() {
    _closed = true;
    Navigator.of(context).pop();
  }

  Widget _dialog(
    BuildContext context,
    XbDomainSubscription? subscription, {
    required bool profileRefreshing,
  }) {
    final ownerCurrent = _ownerCurrent;
    final cents = _resetCents;
    final now = DateTime.now();
    final offerAvailable =
        subscription != null && _offerAvailable(subscription, now);
    final canSubmit =
        ownerCurrent &&
        offerAvailable &&
        !profileRefreshing &&
        !_loading &&
        !_submitting &&
        _loadError == null &&
        cents != null;
    final theme = Theme.of(context);
    final t = XbTokens.of(context);
    final text = theme.textTheme;
    final inset = Color.lerp(t.sf2, t.sfc, 0.64)!;
    final nextReset = subscription?.nextResetAt;
    final days = subscription?.resetDay;
    final hasUpcomingReset =
        nextReset?.isAfter(now) ??
        (days != null && days >= 0);
    final resetLabel = nextReset != null
        ? xbRemainLabel(nextReset, now: now, expiredText: '重置时间已过')
        : days == null || days < 0
        ? '未提供'
        : days == 0
        ? '今天'
        : '剩余 $days 天';
    return AlertDialog(
      backgroundColor: t.sf2,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      titlePadding: const EdgeInsets.fromLTRB(18, 22, 18, 0),
      contentPadding: const EdgeInsets.fromLTRB(18, 15, 18, 0),
      actionsPadding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XbTokens.rLg + 6),
      ),
      scrollable: true,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('流量重置包购买须知', textAlign: TextAlign.center),
          if (subscription != null) ...[
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                text: '已用流量：',
                children: [
                  TextSpan(
                    text: '${_usedPercent(subscription)}%',
                    style: TextStyle(color: t.on, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: t.onv),
            ),
          ],
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!ownerCurrent || (subscription == null && !profileRefreshing))
            const Text('账号或套餐状态已变化，请关闭后重新打开。'),
          if (subscription != null)
            DecoratedBox(
              decoration: BoxDecoration(
                color: inset,
                borderRadius: BorderRadius.circular(XbTokens.rMd),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                  children: [
                    _impactRow(
                      context,
                      label: '套餐到期日',
                      value: subscription.expiredAt == null
                          ? '长期有效'
                          : xbRemainLabel(
                              subscription.expiredAt!,
                              now: now,
                              expiredText: '已过期',
                            ),
                      detail: subscription.expiredAt == null
                          ? null
                          : xbDateMinute(subscription.expiredAt!),
                    ),
                    Divider(color: t.line),
                    _impactRow(
                      context,
                      label: '下次自动重置',
                      value: resetLabel,
                      detail: nextReset == null
                          ? null
                          : xbDateMinute(nextReset),
                    ),
                    Divider(color: t.line),
                    _impactRow(
                      context,
                      label: '重置包价格',
                      value: _loading
                          ? '查询中…'
                          : cents == null
                          ? '未提供'
                          : xbYuan(cents / 100),
                    ),
                  ],
                ),
              ),
            ),
          if (ownerCurrent && (subscription != null || profileRefreshing)) ...[
            if (_loading || profileRefreshing) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ] else if (_loadError case final error?) ...[
              const SizedBox(height: 8),
              Text(resolveErrorText(error, fallback: '暂时无法获取重置价格')),
            ] else if (cents == null) ...[
              const SizedBox(height: 8),
              const Text('当前套餐不支持单独购买流量重置包，或暂未提供有效价格。'),
            ],
            if (subscription != null && !offerAvailable) ...[
              const SizedBox(height: 8),
              const Text('当前套餐已过期，请续费或选购套餐。'),
            ],
            if (subscription != null) ...[
              const SizedBox(height: 11),
              Text(
                hasUpcomingReset
                    ? '购买成功后，已用流量立即清零。重置包仅在下次自动重置前有效，届时未用完的流量将清零。'
                    : '购买成功后，已用流量立即清零。如有自动重置，届时未用完的流量将清零。',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: t.onv, height: 1.4),
              ),
              const SizedBox(height: 11),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.info_outline, color: t.onv, size: 16),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '流量重置包不会延长套餐有效期。',
                      style: text.bodySmall?.copyWith(
                        color: t.on,
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
      actions: [
        if (ownerCurrent && subscription != null && _loadError != null)
          TextButton(
            onPressed: _loading ? null : () => _load(retry: true),
            child: const Text('重试'),
          ),
        XbPurchaseActions(
          confirmLabel: _submitting ? '正在核对订单…' : '确认购买',
          onCancel: _submitting && ownerCurrent ? null : _close,
          onConfirm: canSubmit ? () => _submitOrder(subscription) : null,
        ),
      ],
    );
  }

  Widget _impactRow(
    BuildContext context, {
    required String label,
    required String value,
    String? detail,
  }) {
    final t = XbTokens.of(context);
    final text = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: text.bodySmall?.copyWith(color: t.onv)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    value,
                    textAlign: TextAlign.end,
                    style: text.titleSmall?.copyWith(
                      color: t.on,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      textAlign: TextAlign.end,
                      style: text.labelMedium?.copyWith(
                        color: t.onv,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _usedPercent(XbDomainSubscription subscription) {
    final percent = subscription.usedBytes >= subscription.totalBytes
        ? 100.0
        : (subscription.usedBytes * 1000 ~/ subscription.totalBytes) / 10;
    return percent.toStringAsFixed(1);
  }

  Widget _subscriptionDetails(XbDomainSubscription subscription) {
    final expiry = subscription.expiredAt;
    final nextReset = subscription.nextResetAt;
    final resetDays = subscription.resetDay;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text('已用流量：${_usedPercent(subscription)}%'),
        Text(
          expiry == null
              ? '套餐到期：长期有效'
              : '套餐到期：${xbDate(expiry)}（${xbRemainLabel(expiry, expiredText: '已过期')}）',
        ),
        Text(
          nextReset != null
              ? '下次重置：${xbDateMinute(nextReset)}'
              : resetDays != null && resetDays >= 0
              ? '下次重置：${resetDays == 0 ? '今天' : '剩余 $resetDays 天'}'
              : '下次重置：未提供',
        ),
      ],
    );
  }

  /// 当前套餐不提供单独的流量重置包（复用 XbEmptyState）。
  Widget _unavailable(BuildContext context) {
    return XbEmptyState(
      icon: Icons.info_outline_rounded,
      title: '当前套餐不支持单独购买流量重置包',
      description: '你可以前往「购买套餐」续费或升级套餐以恢复流量。',
      actionLabel: '返回',
      onAction: _close,
    );
  }

  Widget _content(
    BuildContext context,
    XbDomainSubscription subscription,
    PlanItem plan,
    int resetCents,
    bool wide,
    VoidCallback? onSubmit,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        XbCard(child: _subscriptionDetails(subscription)),
        const SizedBox(height: 16),
        // 价格卡（复用 XbCard）。
        XbCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '流量重置包',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '一次性恢复 ${plan.transferEnableGb} GB 流量',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                xbYuan(resetCents / 100),
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        // 桌面：提交按钮内联列底（原型屏37 `.pbtn fill`）；窄屏用固定底栏（见 _bottomBar）。
        if (wide) ...[
          const SizedBox(height: 16),
          XbPrimaryButton(
            label: '提交订单',
            icon: Icons.shopping_cart_checkout_rounded,
            loading: _submitting,
            onPressed: onSubmit,
          ),
        ],
      ],
    );
  }

  Widget? _bottomBar(VoidCallback onSubmit) {
    if (_loading || _loadError != null || _resetCents == null) return null;
    return XbBottomActionBar(
      primaryLabel: '提交订单',
      primaryIcon: Icons.shopping_cart_checkout_rounded,
      primaryLoading: _submitting,
      onPrimary: onSubmit,
    );
  }

  Future<void> _submitOrder(XbDomainSubscription displayedSubscription) async {
    final cents = _resetCents;
    final plan = _plan;
    if (!mounted ||
        _submitting ||
        _loading ||
        _loadError != null ||
        cents == null ||
        plan == null ||
        plan.id != widget.planId) {
      return;
    }
    if (!_ownerCurrent) return;
    final planId = widget.planId;
    final expectedSubscription = ConfirmedOrderSubscription(
      planId: displayedSubscription.planId,
      totalBytes: displayedSubscription.totalBytes,
      expiredAt: displayedSubscription.expiredAt,
    );
    bool subscriptionCurrent() {
      final profile = ref.read(userProfileProvider);
      return !profile.isLoading &&
          _matchingSubscription(profile) == displayedSubscription &&
          _offerAvailable(displayedSubscription, DateTime.now()) &&
          expectedSubscription.matches(
            displayedSubscription.planId,
            displayedSubscription.totalBytes,
            displayedSubscription.expiredAt,
          );
    }

    bool current() =>
        _ownerCurrent &&
        widget.planId == planId &&
        _resetCents == cents &&
        subscriptionCurrent();
    if (!current()) return;
    setState(() => _submitting = true);
    try {
      final result = await submitConfirmedOrder(
        context: context,
        service: _ownerService,
        isActive: current,
        quote: ConfirmedOrderQuote(
          planId: planId,
          planName: displayedSubscription.planName ?? widget.planName ?? plan.name,
          period: XbPlanPeriod.resetTraffic,
          estimatedCents: cents,
          catalogCents: cents,
          expectedSubscription: expectedSubscription,
        ),
      );
      if (!mounted || !current()) return;
      switch (result) {
        case XbSuccess(:final data):
          if (data == null) return;
          _showOrderDestination(OrderPaymentPage(tradeNo: data));
        case XbFailure(:final error):
          if (error is XbUnconfirmed) {
            xbToastSafe(resolveErrorText(error));
            if (mounted) {
              _showOrderDestination(const OrderListPage());
            }
            return;
          }
          xbToastSafe('提交订单失败：${resolveErrorText(error, fallback: '请稍后重试')}');
      }
    } catch (error, stack) {
      // Unexpected transport exceptions may follow a server-side write. Never replay.
      if (!mounted || !current()) return;
      SentryBootstrap.captureException(
        error,
        stackTrace: stack,
        where: 'reset traffic order',
      );
      xbToastSafe('订单结果暂未确认，请前往订单记录核对，勿重复提交。');
      _showOrderDestination(const OrderListPage());
    } finally {
      if (mounted && !_closed) setState(() => _submitting = false);
    }
  }
}
