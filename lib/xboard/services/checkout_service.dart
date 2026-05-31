/// 结算编排（R8 / 数据一致性 § H retryableCheckout + § I 订单状态机 + θ-7 processing 超时）。
///
/// **retryableCheckout（§ H）**：先查 pending 订单（同 planId）→ 有则复用旧 tradeNo 直接 checkout
/// （不重 createOrder，防网络中断重点产生重复订单）；无则正常 createOrder + checkout。
///
/// **OrderStatus 状态机（§ I）**：仅 pending/processing 两态需轮询；终态（cancelled/completed/
/// discounted）停轮询；completed/discounted 触发 R7 同步（T3）。
///
/// **processing 5min 超时（R8.7.bis / θ-7）**：SDK OrderModel 无 paid_at →「客户端首次观测进入
/// processing 的本地时刻」+ 300s；超时判定用单调时钟（防改系统时间绕过）。
library;

import '../models/checkout_outcome_ui.dart';
import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';

/// processing 超时阈值（R8.7.bis / F381，后端 check:traffic-exceeded 分钟级）。
const Duration kProcessingTimeout = Duration(minutes: 5);

class CheckoutService {
  CheckoutService({required XboardService service}) : _service = service;

  final XboardService _service;

  /// 首次观测进入 processing 的单调计时（θ-7，按 tradeNo；防改系统时间绕过）。
  final Map<String, Stopwatch> _processingSince = {};

  /// retryableCheckout（§ H）：有 pending（同 planId）复用，否则新建。
  /// 返回 (tradeNo, checkout 结果)。
  Future<XbResult<CheckoutOutcomeUi>> retryableCheckout({
    required int planId,
    required XbPlanPeriod period,
    required String method,
    String? couponCode,
  }) async {
    // 1. 查 pending 订单（首页 5 条够用）。
    final ordersResult = await _service.getOrders(page: 1, pageSize: 5);
    String? reuseTradeNo;
    if (ordersResult case XbSuccess(:final data)) {
      for (final o in data.items) {
        if (o.status == XbOrderStatus.pending) {
          reuseTradeNo = o.tradeNo;
          break;
        }
      }
    }

    // 2. 复用或新建 tradeNo。
    final String tradeNo;
    if (reuseTradeNo != null) {
      tradeNo = reuseTradeNo; // 复用 pending，不重 createOrder（防重复下单）。
    } else {
      final created =
          await _service.createOrder(planId, period, couponCode: couponCode);
      if (created case XbFailure(:final error)) {
        return XbResult.failure(error);
      }
      tradeNo = (created as XbSuccess<String>).data;
    }

    // 3. checkout。
    return _service.checkout(tradeNo, method);
  }

  /// 是否需要继续轮询（§ I：仅 pending/processing 两态）。
  bool shouldPoll(XbOrderStatus status) =>
      status == XbOrderStatus.pending || status == XbOrderStatus.processing;

  /// 是否终态（停轮询）。
  bool isTerminal(XbOrderStatus status) =>
      status == XbOrderStatus.cancelled ||
      status == XbOrderStatus.completed ||
      status == XbOrderStatus.discounted;

  /// 是否触发 R7 同步（completed/discounted → T3）。
  bool shouldTriggerSync(XbOrderStatus status) =>
      status == XbOrderStatus.completed || status == XbOrderStatus.discounted;

  /// 记录进入 processing（首次观测，θ-7 单调计时起点）。
  void markProcessing(String tradeNo) {
    _processingSince.putIfAbsent(tradeNo, () => Stopwatch()..start());
  }

  /// processing 是否已超时（θ-7 单调时钟；未记录过返 false）。
  bool isProcessingTimedOut(String tradeNo) {
    final sw = _processingSince[tradeNo];
    if (sw == null) return false;
    return sw.elapsed >= kProcessingTimeout;
  }

  /// 清理 processing 计时（终态 / 离开页面）。
  void clearProcessing(String tradeNo) => _processingSince.remove(tradeNo);
}
