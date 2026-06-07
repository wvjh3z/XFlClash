/// 待支付订单区块（我的 / 续费 / 购买 / 流量重置 四处复用）。
///
/// 监听 [pendingOrderProvider]：有 pending 订单 → 渲染 [XbPendingOrderBanner]；无 → 收起（零高度）。
/// - 立即支付 → push [OrderPaymentPage]（带订单号）。
/// - 取消订单 → 二次确认 → 反腐层 `cancelOrder` → 刷新 provider（横幅消失）。
///
/// **永不打断主流程**：取消失败 toast 提示；provider 失败/无单不显示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/xboard_config.dart';
import '../models/order_summary.dart';
import '../models/xb_result.dart';
import '../providers/pending_order_provider.dart';
import '../providers/xboard_providers.dart';
import '../util/period_label.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_theme.dart' show xbPush, xbShowDialog;
import 'order_payment_page.dart';

class PendingOrderSection extends ConsumerStatefulWidget {
  const PendingOrderSection({super.key});

  @override
  ConsumerState<PendingOrderSection> createState() =>
      _PendingOrderSectionState();
}

class _PendingOrderSectionState extends ConsumerState<PendingOrderSection> {
  bool _cancelling = false;
  // 已取消的订单号（乐观隐藏：取消成功后立即不再显示该单，不等后端重查落定）。
  final Set<String> _cancelledTradeNos = {};

  @override
  void initState() {
    super.initState();
    // 进页强制重查（FutureProvider 默认只首拉一次；不刷新则进页看不到最新待支付状态，
    // 须冷启动才更新）。延后到首帧后 invalidate，避免 build 期改 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(pendingOrderProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(pendingOrderProvider);
    final order = async.asData?.value;
    // 无订单 / 该单已被本地取消 → 收起。
    if (order == null || _cancelledTradeNos.contains(order.tradeNo)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: XbPendingOrderBanner(
        subtitle: _subtitle(order),
        amountText: '¥${order.totalAmountYuan.toStringAsFixed(2)}',
        cancelling: _cancelling,
        onPay: () => _pay(order),
        onCancel: () => _confirmCancel(order),
      ),
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
      brandColor: Color(XboardConfig.current.brandColor),
    );
    // 从支付页返回后重查（可能已支付完成 → 横幅应消失）。
    if (mounted) ref.invalidate(pendingOrderProvider);
  }

  Future<void> _confirmCancel(OrderSummary o) async {
    final ok = await xbShowDialog<bool>(
      context: context,
      brandColor: Color(XboardConfig.current.brandColor),
      builder: (ctx) => AlertDialog(
        title: const Text('取消订单'),
        content: const Text('确定要取消这笔待支付订单吗？取消后需重新下单。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('取消订单'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _doCancel(o);
  }

  Future<void> _doCancel(OrderSummary o) async {
    setState(() => _cancelling = true);
    try {
      final result =
          await ref.read(xboardServiceProvider).cancelOrder(o.tradeNo);
      if (!mounted) return;
      switch (result) {
        case XbSuccess():
          _cancelledTradeNos.add(o.tradeNo); // 乐观隐藏，立即消失
          ref.invalidate(pendingOrderProvider); // 后台重查对齐后端
          _toast('订单已取消');
        case XbFailure(:final error):
          _toast('取消失败：${error.message}');
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
