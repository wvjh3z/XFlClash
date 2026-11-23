/// 待支付订单 provider（R9 衍生）：查订单列表，取**第一个 pending 订单**。
///
/// 页面不再主动展示顶部待支付横幅。这个读模型不参与提交时的旧单核验。
///
/// 查询失败进入 AsyncError；只有成功查询无待付才返回 null。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/order_summary.dart';
import '../models/xb_result.dart';
import 'xboard_providers.dart';
import 'auth_state_provider.dart';
import 'xboard_connectivity_provider.dart';
import '../models/xb_domain_error.dart';

/// 当前待支付订单（最近一个 pending；无则 null）。autoDispose：进页拉、离页回收。
///
/// **forceRefresh=true**：SDK adapter 把订单全量缓存在内存（`_cachedAllOrders`），不强刷则
/// 取消/支付后仍返旧缓存（须冷启动才更新）。本 provider 每次执行都强刷,保证待支付状态实时。
final pendingOrderProvider = FutureProvider.autoDispose<OrderSummary?>((
  ref,
) async {
  if (ref.watch(authStateProvider) != AuthState.authenticated) return null;
  if (ref.read(isOfflineProvider)) throw const XbNetwork(XbNetworkKind.connectionFailed, '当前离线');
  final result = await ref
      .watch(xboardServiceProvider)
      .getOrders(forceRefresh: true);
  return switch (result) {
    XbSuccess(:final data) => _firstPending(data.items),
    XbFailure(:final error) => throw error,
  };
}, retry: (retryCount, error) => null);

OrderSummary? _firstPending(List<OrderSummary> items) {
  for (final o in items) {
    if (o.canContinuePayment) return o;
  }
  return null;
}
