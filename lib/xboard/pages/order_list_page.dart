/// R9 订单列表页：拉订单列表 → 点进详情。
///
/// **数据源**：反腐层 `getOrders()` / `getOrder()`。永不抛（XbResult）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush, XbTokens;
import '../models/order_summary.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../util/format.dart';
import '../util/period_label.dart';
import '../widgets/xb_ui_kit.dart';
import 'order_payment_page.dart';

class OrderListPage extends ConsumerStatefulWidget {
  const OrderListPage({super.key});

  @override
  ConsumerState<OrderListPage> createState() => _OrderListPageState();
}

class _OrderListPageState extends ConsumerState<OrderListPage> {
  late Future<List<OrderSummary>> _ordersFuture;

  /// 重试中：顶部「正在刷新服务」黄条（后台切域名重拉）。
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _ordersFuture = _loadOrders();
  }

  Future<List<OrderSummary>> _loadOrders() async {
    // 强制实时拉服务端（绕过 SDK _cachedAllOrders 缓存）：否则新建的待支付订单不在缓存里、
    // 进页面看不到，且缓存命中会让转圈一闪而过（用户报告「没转圈、没显示」的根因）。
    final result =
        await ref.read(xboardServiceProvider).getOrders(forceRefresh: true);
    return switch (result) {
      XbSuccess(:final data) => data.items,
      XbFailure(:final error) => throw error, // 抛领域错误，error 分支还原文案
    };
  }

  void _reload() {
    setState(() {
      _retrying = true;
      _ordersFuture = _loadOrders();
    });
    _ordersFuture.whenComplete(() {
      if (mounted) setState(() => _retrying = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return XbBrandScaffold(
      title: '我的订单',
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<OrderSummary>>(
          future: _ordersFuture,
          builder: (context, snap) {
            final done = snap.connectionState == ConnectionState.done;
            return XbAsyncView(
              loading: !done && !_retrying,
              retrying: _retrying,
              error: done ? snap.error : null,
              errorFallback: '加载订单失败',
              onRetry: _reload,
              builder: (context) {
                final orders = snap.data ?? const <OrderSummary>[];
                if (orders.isEmpty) {
                  return ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('暂无订单记录')),
                    ],
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: orders.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _OrderTile(
                    order: orders[i],
                    onTap: () => xbPush(
                      context,
                      OrderPaymentPage(tradeNo: orders[i].tradeNo),
                      brandColor: xbBrandColor(),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order, required this.onTap});
  final OrderSummary order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final dateStr = xbDate(order.createdAt);

    // 状态 → 图标 + 语义色（原型 .ocard 左侧圆角图标方块）。
    final (statusColor, statusIcon) = switch (order.status) {
      XbOrderStatus.completed ||
      XbOrderStatus.discounted =>
        (XbTokens.ok, Icons.check_circle),
      XbOrderStatus.cancelled => (XbTokens.bad, Icons.cancel),
      XbOrderStatus.pending ||
      XbOrderStatus.processing =>
        (XbTokens.warn, Icons.schedule),
    };

    return Material(
      color: t.card,
      borderRadius: BorderRadius.circular(XbTokens.rMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(XbTokens.rMd),
            border: Border.all(color: t.line),
            boxShadow: t.shadow1,
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // 左侧状态图标方块（柔色底）。
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(XbTokens.rSm),
                ),
                child: Icon(statusIcon, size: 21, color: statusColor),
              ),
              const SizedBox(width: 12),
              // 中间：套餐名（加粗，过长省略）+ 周期 · 日期。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      order.planName ?? '套餐订单',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: t.on,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${planPeriodLabel(order.period)} · $dateStr',
                      style: TextStyle(fontSize: 11.5, color: t.onv),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // 右侧：金额（上）+ 状态 chip（下），右对齐成列。
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    xbYuan(order.totalAmountYuan),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: t.on,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 6),
                  XbTag(orderStatusLabel(order.status), color: statusColor),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
