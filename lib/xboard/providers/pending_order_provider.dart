/// 待支付订单 provider（R9 衍生）：查订单列表，取**第一个 pending 订单**。
///
/// 用于「我的 / 续费 / 购买 / 流量重置」四处顶部的待支付横幅（[XbPendingOrderBanner]）：
/// 有 pending 订单才显示横幅，提供「取消订单 / 立即支付」两个操作。
///
/// **永不抛**：失败/无订单 → 返回 null（横幅不显示），不打断主流程。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/order_summary.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import 'xboard_providers.dart';

/// 当前待支付订单（最近一个 pending；无则 null）。autoDispose：进页拉、离页回收。
final pendingOrderProvider = FutureProvider.autoDispose<OrderSummary?>((ref) async {
  final result = await ref.read(xboardServiceProvider).getOrders();
  return switch (result) {
    XbSuccess(:final data) => _firstPending(data.items),
    XbFailure() => null, // 失败静默，横幅不显示
  };
});

OrderSummary? _firstPending(List<OrderSummary> items) {
  for (final o in items) {
    if (o.status == XbOrderStatus.pending) return o;
  }
  return null;
}
