/// R9 订单列表页：拉订单列表 → 点进详情。
///
/// **数据源**：反腐层 `getOrders()` / `getOrder()`。永不抛（XbResult）。
library;

import 'package:fl_clash/xboard/widgets/xb_emoji_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/xb_async_view.dart';
import '../widgets/xb_network_read_recovery.dart';
import '../providers/xboard_connectivity_provider.dart';
import '../models/xb_domain_error.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor;
import '../widgets/xb_theme.dart' show xbPush, XbTokens;
import '../models/order_summary.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../providers/auth_state_provider.dart';
import '../providers/pending_order_provider.dart';
import '../providers/xboard_providers.dart';
import '../sdk/xboard_service.dart';
import '../util/format.dart';
import '../util/period_label.dart';
import '../widgets/xb_ui_kit.dart';
import 'order_payment_page.dart';
import 'commerce_read_recovery.dart';

class OrderListPage extends ConsumerWidget {
  const OrderListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(authStateProvider) != AuthState.authenticated) {
      return const XbBrandScaffold(title: '我的订单', body: Center(child: Text('请先登录后查看订单')));
    }
    final service = ref.watch(xboardServiceProvider);
    final revision = ref.watch(authStateProvider.notifier).sessionRevision;
    return _OwnedOrderList(key: ValueKey((service, revision)), service: service, revision: revision);
  }
}

class _OwnedOrderList extends ConsumerStatefulWidget {
  const _OwnedOrderList({super.key, required this.service, required this.revision});
  final XboardService service;
  final int revision;
  @override
  ConsumerState<_OwnedOrderList> createState() => _OrderListPageState();
}

class _OrderListPageState extends ConsumerState<_OwnedOrderList> {
  bool get _current => mounted && ref.read(authStateProvider) == AuthState.authenticated &&
      ref.read(authStateProvider.notifier).sessionRevision == widget.revision &&
      identical(ref.read(xboardServiceProvider), widget.service);
  late Future<List<OrderSummary>> _ordersFuture;

  /// 重试中：顶部「正在刷新服务」黄条（后台切域名重拉）。
  bool _retrying = false;
  bool _openingOrder = false;
  List<OrderSummary>? _snapshot;
  Object? _lastError;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _ordersFuture = _loadOrders();
  }

  Future<List<OrderSummary>> _loadOrders() async {
    _reading = true;
    try {
      if (ref.read(isOfflineProvider)) throw const XbNetwork(XbNetworkKind.connectionFailed, '当前离线');
      final rows = await _fetchOrders();
      if (_current) { _snapshot = rows; _lastError = null; }
      return rows;
    } catch (error) {
      if (_current) {
        _lastError = error;
        if (!xbIsRecoverableReadError(error)) _snapshot = null;
      }
      rethrow;
    } finally {
      _reading = false;
    }
  }

  Future<List<OrderSummary>> _fetchOrders() async {
    if (!_current) return const [];
    final service = widget.service;
    final orders = <OrderSummary>[];
    // SDK 对同一个全量快照本地分页。仅首批强刷，不能遗漏后一页的待付订单。
    for (var page = 1; ; page++) {
      final result = await service.getOrders(
        page: page,
        pageSize: 50,
        forceRefresh: page == 1,
      );
      if (!_current) {
        return const [];
      }
      switch (result) {
        case XbFailure(:final error):
          throw error;
        case XbSuccess(:final data):
          orders.addAll(data.items);
          if (orders.length >= data.total) return orders;
          if (data.items.isEmpty || data.page != page) {
            throw StateError('订单列表未加载完整');
          }
      }
    }
  }

  Future<void> _reload() async {
    if (!_current) return;
    if (_reading) { try { await _ordersFuture; } catch (_) {} return; }
    final request = _loadOrders();
    setState(() {
      _retrying = true;
      _ordersFuture = request;
    });
    try {
      await request;
    } catch (_) {
      // FutureBuilder retains the original error for the page's retry UI.
      // This completion Future only drives refresh state; it must not leak it.
    } finally {
      if (mounted && identical(_ordersFuture, request)) {
        setState(() => _retrying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(isOfflineProvider);
    xbListenForReadRecovery(context, ref, () {
      recoverCommerceRead(context: context, current: () => _current, pending: _reading && !_retrying ? _ordersFuture : null,
        retryIfFailed: () async {
          if (!_reading && xbIsRecoverableReadError(_lastError)) await _reload();
        });
    });
    return XbBrandScaffold(
      title: '我的订单',
      // 桌面订单页用更宽（双列网格，原型屏7）；移动端 <1000 不受影响。
      maxContentWidth: 1000,
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<OrderSummary>>(
          future: _ordersFuture,
          builder: (context, snap) {
            final done = snap.connectionState == ConnectionState.done;
            if (_snapshot != null && (offline || _lastError != null || _retrying)) {
              return Column(children: [
                Text(_retrying ? '正在刷新订单，显示上次记录' : '订单未更新，显示上次记录'),
                if (!offline && !_retrying) TextButton(onPressed: _reload, child: const Text('重新查询订单')),
                Expanded(child: _snapshot!.isEmpty
                    ? const Center(child: Text('上次未查询到订单'))
                    : _OrderGroups(orders: _snapshot!, onOpen: (o) => _openOrder(context, o))),
              ]);
            }
            return XbAsyncView(
              loading: !done && !_retrying,
              retrying: _retrying,
              error: done ? snap.error : null,
              errorFallback: '加载订单失败',
              skeleton: XbSkeletonKind.list,
              onRetry: _reload,
              builder: (context) {
                final orders = snap.data ?? const <OrderSummary>[];
                if (orders.isEmpty) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('暂无订单记录')),
                    ],
                  );
                }
                return _OrderGroups(
                  orders: orders,
                  onOpen: (order) => _openOrder(context, order),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _openOrder(BuildContext context, OrderSummary order) async {
    if (!_current || _openingOrder || order.needsVerification) return;
    _openingOrder = true;
    try {
      await xbPush<void>(
        context,
        OrderPaymentPage(tradeNo: order.tradeNo),
        brandColor: xbBrandColor(),
      );
      if (!_current) {
        return;
      }
      ref.invalidate(pendingOrderProvider);
      await _reload();
    } finally {
      _openingOrder = false;
    }
  }
}

class _OrderGroups extends StatelessWidget {
  const _OrderGroups({required this.orders, required this.onOpen});

  final List<OrderSummary> orders;
  final ValueChanged<OrderSummary> onOpen;

  VoidCallback? _action(OrderSummary order) =>
      order.needsVerification ? null : () => onOpen(order);

  @override
  Widget build(BuildContext context) {
    final pending = <OrderSummary>[];
    final history = <OrderSummary>[];
    final unverified = <OrderSummary>[];
    for (final order in orders) {
      (order.needsVerification ? unverified : order.canContinuePayment ? pending : history).add(order);
    }
    final t = XbTokens.of(context);
    const corner = Radius.circular(XbTokens.rLg);
    const radius = BorderRadius.all(corner);

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoCol = constraints.maxWidth >= 700;

        Widget desktopTile(OrderSummary order) => XbCard(
          padding: EdgeInsets.zero,
          radius: XbTokens.rLg,
          onTap: _action(order),
          child: _OrderSummaryRow(order: order),
        );

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              sliver: SliverMainAxisGroup(
                slivers: [
                  if (pending.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: _OrderGroupLabel('需要处理')),
                    SliverList.separated(
                      itemCount: pending.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, index) => _PendingOrderCard(
                        order: pending[index],
                        onContinue: _action(pending[index]),
                      ),
                    ),
                  ],
                  if (unverified.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: _OrderGroupLabel('待核实订单')),
                    SliverList.builder(itemCount: unverified.length,
                      itemBuilder: (_, index) => desktopTile(unverified[index])),
                  ],
                  if (history.isNotEmpty) ...[
                    if (pending.isNotEmpty)
                      const SliverToBoxAdapter(child: SizedBox(height: 12)),
                    const SliverToBoxAdapter(child: _OrderGroupLabel('历史订单')),
                    if (twoCol)
                      SliverList.separated(
                        itemCount: (history.length + 1) ~/ 2,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, index) {
                          final start = index * 2;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: desktopTile(history[start])),
                              const SizedBox(width: 12),
                              Expanded(
                                child: start + 1 < history.length
                                    ? desktopTile(history[start + 1])
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          );
                        },
                      )
                    else
                      DecoratedSliver(
                        decoration: BoxDecoration(
                          color: t.card,
                          border: Border.all(color: t.line),
                          borderRadius: radius,
                        ),
                        sliver: SliverList.separated(
                          itemCount: history.length,
                          separatorBuilder: (_, _) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: Divider(
                              height: 1,
                              thickness: 1,
                              color: t.hair,
                            ),
                          ),
                          itemBuilder: (_, index) {
                            final order = history[index];
                            final row = _OrderSummaryRow(order: order);
                            final onTap = _action(order);
                            if (onTap == null) return row;
                            return Material(
                              type: MaterialType.transparency,
                              child: InkWell(
                                onTap: onTap,
                                borderRadius: BorderRadius.vertical(
                                  top: index == 0 ? corner : Radius.zero,
                                  bottom: index == history.length - 1
                                      ? corner
                                      : Radius.zero,
                                ),
                                child: row,
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OrderGroupLabel extends StatelessWidget {
  const _OrderGroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 5, 3, 8),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: XbTokens.of(context).on,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _PendingOrderCard extends StatelessWidget {
  const _PendingOrderCard({required this.order, required this.onContinue});

  final OrderSummary order;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    return XbCard(
      padding: EdgeInsets.zero,
      radius: XbTokens.rLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _OrderSummaryRow(order: order),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 0, 13, 12),
            child: XbGradientAction(
              onPressed: onContinue,
              height: 44,
              child: const Text('继续支付'),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderSummaryRow extends StatelessWidget {
  const _OrderSummaryRow({required this.order});

  final OrderSummary order;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final pending = order.canContinuePayment;
    final period = order.period == XbPlanPeriod.resetTraffic
        ? XbPlanPeriod.onetime
        : order.period;
    final statusColor = switch (order.status) {
      null => t.onv,
      XbOrderStatus.completed ||
      XbOrderStatus.discounted => XbTokens.ok,
      XbOrderStatus.cancelled => XbTokens.bad,
      XbOrderStatus.pending ||
      XbOrderStatus.processing => XbTokens.warn,
    };

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: pending ? 14 : 12),
      child: Row(
        children: [
          if (pending) ...[
            XbIconBadge(
              icon: Icons.schedule,
              size: 38,
              radius: XbTokens.rMd,
              background: statusColor.withValues(alpha: 0.14),
              iconColor: statusColor,
              iconSize: 21,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                XbEmojiText(
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
                  '${planPeriodLabel(period)} · ${xbDate(order.createdAt)}',
                  style: TextStyle(fontSize: 11.5, color: t.onv),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                order.totalAmountYuan == null ? '金额待核实' : xbYuan(order.totalAmountYuan!),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: t.on,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 6),
              if (pending)
                DecoratedBox(
                  decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(XbTokens.rSm)),
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3), child: Text(orderStatusLabel(order.status), style: TextStyle(color: statusColor, fontSize: 11, height: 15 / 11, fontWeight: FontWeight.w600))),
                )
              else XbTag(order.needsVerification ? '状态待核实' : orderStatusLabel(order.status), color: order.needsVerification ? t.onv : statusColor),
            ],
          ),
        ],
      ),
    );
  }
}
