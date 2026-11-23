/// 待支付订单区块（我的 / 续费 / 购买 / 流量重置 四处复用）。
///
/// 监听 [pendingOrderProvider]：有 pending 订单 → 渲染 [XbPendingOrderBanner]；无 → 收起（零高度）。
/// - 立即支付 → push [OrderPaymentPage]（带订单号）。
/// - 取消订单 → 二次确认 → 反腐层 `cancelOrder` → 刷新 provider（横幅消失）。
///
/// **永不打断主流程**：取消失败 toast 提示；provider 失败/无单不显示。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/order_summary.dart';
import '../models/xb_result.dart';
import '../providers/pending_order_provider.dart';
import '../providers/xboard_connectivity_provider.dart';
import '../widgets/xb_network_read_recovery.dart';
import '../providers/auth_state_provider.dart';
import '../sdk/xboard_service.dart';
import '../models/xb_domain_error.dart';
import '../providers/xboard_providers.dart';
import '../util/error_text.dart';
import '../util/period_label.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbConfirm, xbBrandColor, XbStateToast;
import '../widgets/xb_submit_guard.dart';
import '../widgets/xb_theme.dart' show xbPush;
import '../util/format.dart';
import 'order_payment_page.dart';
import 'commerce_read_recovery.dart';

class PendingOrderSection extends ConsumerStatefulWidget {
  const PendingOrderSection({super.key});

  @override
  ConsumerState<PendingOrderSection> createState() =>
      _PendingOrderSectionState();
}

class _PendingOrderSectionState extends ConsumerState<PendingOrderSection>
    with XbSubmitGuard<PendingOrderSection> {
  // 已取消的订单号（乐观隐藏：取消成功后立即不再显示该单，不等后端重查落定）。
  final Set<String> _cancelledTradeNos = {};
  Object? _owner;
  OrderSummary? _last;

  @override
  void initState() {
    super.initState();
    // 进页刷新待支付状态：仅当 provider 被后台页面（push 栈下方）保活、持有旧值时才强刷；
    // 首次进入时 autoDispose 已重建并拉取最新数据（postFrame 时仍在 loading、无 value）→ 跳过，
    // 避免「首拉 + invalidate 二拉」的进页双拉（order/fetch 翻倍）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(pendingOrderProvider).hasValue) {
        ref.invalidate(pendingOrderProvider);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStateProvider);
    final owner = (auth, ref.read(authStateProvider.notifier).sessionRevision,
      auth == AuthState.authenticated ? ref.watch(xboardServiceProvider) : null);
    if (_owner != owner) {
      _owner = owner;
      _last = null;
      _cancelledTradeNos.clear();
    }
    final async = ref.watch(pendingOrderProvider);
    if (auth != AuthState.authenticated) return const SizedBox.shrink();
    final offline = ref.watch(isOfflineProvider);
    xbListenForReadRecovery(context, ref, () {
      final latest = ref.read(pendingOrderProvider);
      recoverCommerceRead(context: context,
        current: () => _owner == owner && ref.read(authStateProvider) == AuthState.authenticated &&
            ref.read(authStateProvider.notifier).sessionRevision == owner.$2 &&
            identical(ref.read(xboardServiceProvider), owner.$3),
        pending: latest.isLoading ? ref.read(pendingOrderProvider.future) : null,
        retryIfFailed: () async {
          final pending = ref.read(pendingOrderProvider);
          if (!pending.isLoading && xbIsRecoverableReadError(pending.error)) ref.invalidate(pendingOrderProvider);
        });
    });
    if (async.hasError && !xbIsRecoverableReadError(async.error)) _last = null;
    if (!async.isLoading && !async.hasError && async.hasValue) _last = async.asData?.value;
    if (async.hasError || (offline || async.isLoading) && _last != null) {
      final previous = _last;
      return Column(children: [
        Text(previous == null ? '待支付订单状态待核实' : '上次待支付：${_subtitle(previous)}（状态待核实）'),
        TextButton(onPressed: offline || async.isLoading ? null : () => ref.invalidate(pendingOrderProvider),
          child: const Text('重新查询订单')),
      ]);
    }
    final order = async.asData?.value;
    // 无订单 / 该单已被本地取消 → 收起。
    if (order == null || !order.canContinuePayment || _cancelledTradeNos.contains(order.tradeNo)) {
      return const SizedBox.shrink();
    }

    final banner = XbPendingOrderBanner(
      subtitle: _subtitle(order),
      amountText: xbYuan(order.totalAmountYuan!),
      cancelling: submitting,
      onPay: () => _pay(order),
      onCancel: () => _confirmCancel(order),
    );
    // 桌面（原型 .pendcard max-width:400;margin:0 auto）：横幅收窄居中，不撑满整宽（避免过长）。
    final wide = MediaQuery.sizeOf(context).width >= 840;
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: wide
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: banner,
              ),
            )
          : banner,
    );
  }

  String _subtitle(OrderSummary o) {
    final plan = o.planName ?? '套餐订单';
    return '$plan · ${planPeriodLabel(o.period)}';
  }

  Future<void> _pay(OrderSummary o) async {
    await xbPush(
      context,
      OrderPaymentPage(tradeNo: o.tradeNo),
      brandColor: xbBrandColor(),
    );
    // 从支付页返回后重查（可能已支付完成 → 横幅应消失）。
    if (mounted) ref.invalidate(pendingOrderProvider);
  }

  Future<void> _confirmCancel(OrderSummary o) async {
    if (!mounted || submitting || ref.read(isOfflineProvider)) return;
    final service = ref.read(xboardServiceProvider);
    final revision = ref.read(authStateProvider.notifier).sessionRevision;
    bool current() => mounted && ref.read(authStateProvider) == AuthState.authenticated &&
        ref.read(authStateProvider.notifier).sessionRevision == revision &&
        identical(ref.read(xboardServiceProvider), service);
    final ok = await xbConfirm(
      context,
      title: '取消订单',
      message: '确定要取消这笔待支付订单吗？取消后需重新下单。',
      confirmLabel: '取消订单',
      cancelLabel: '再想想',
      destructive: true,
    );
    if (!ok || !current() || ref.read(isOfflineProvider)) return;
    final pending = ref.read(pendingOrderProvider);
    if (pending.isLoading || pending.hasError || pending.asData?.value?.tradeNo != o.tradeNo) return;
    await _doCancel(o, service, current);
  }

  Future<void> _doCancel(OrderSummary o, XboardService service, bool Function() current) async {
    if (!current()) return;
    await runSubmit(() async {
      if (!current()) return;
      final result = await service.cancelOrder(o.tradeNo);
      if (!current()) return;
      switch (result) {
        case XbSuccess(data: true):
          _cancelledTradeNos.add(o.tradeNo);
          _last = null;
          ref.invalidate(pendingOrderProvider); // 后台重查对齐后端
          xbToastSafe('订单已取消');
        case XbSuccess():
          ref.invalidate(pendingOrderProvider);
          xbToastSafe('取消结果待核实，请重新查询订单');
        case XbFailure(:final error):
          if (error is XbUnconfirmed) ref.invalidate(pendingOrderProvider);
          xbToastSafe(
            error is XbUnconfirmed
                ? resolveErrorText(error)
                : '取消失败：${resolveErrorText(error, fallback: '请稍后重试')}',
          );
      }
    });
  }
}
