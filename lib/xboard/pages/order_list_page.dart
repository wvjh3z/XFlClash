/// R9 订单列表页：拉订单列表 → 点进详情。
///
/// **数据源**：反腐层 `getOrders()` / `getOrder()`。永不抛（XbResult）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush, XbTokens;
import '../models/order_summary.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/xboard_providers.dart';
import '../util/error_text.dart';
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
    final result = await ref.read(xboardServiceProvider).getOrders();
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
            if (snap.connectionState != ConnectionState.done) {
              if (_retrying) {
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: const [XbSyncBanner(text: '正在刷新服务，请稍候…')],
                );
              }
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              final err = snap.error;
              final msg = err is XbDomainError
                  ? resolveErrorText(err, fallback: '加载订单失败')
                  : '加载订单失败';
              return XbErrorRetry(message: msg, onRetry: _reload);
            }
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
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final d = order.createdAt;
    final dateStr = xbDate(d);
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(order.planName ?? '套餐订单',
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(
            '${planPeriodLabel(order.period)} · $dateStr\n${xbYuan(order.totalAmountYuan)}'),
        isThreeLine: true,
        trailing: _StatusChip(status: order.status),
        onTap: onTap,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final XbOrderStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      // 语义色（原型 --ok 绿 / --bad 红 / --warn 琥珀）：已完成=绿，非品牌红。
      XbOrderStatus.completed || XbOrderStatus.discounted => XbTokens.ok,
      XbOrderStatus.cancelled => XbTokens.bad,
      XbOrderStatus.pending || XbOrderStatus.processing => XbTokens.warn,
    };
    return XbTag(orderStatusLabel(status), color: color);
  }
}
