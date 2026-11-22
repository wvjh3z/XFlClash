/// 支付状态展示策略；真实下单统一由 confirmed_order.dart 处理。
/// **OrderStatus 状态机（§ I）**：仅 pending/processing 两态需轮询；终态（cancelled/completed/
/// discounted）停轮询；completed/discounted 触发 R7 同步（T3）。
///
/// **processing 5min 超时（R8.7.bis / θ-7）**：SDK OrderModel 无 paid_at →「客户端首次观测进入
/// processing 的本地时刻」+ 300s；超时判定用单调时钟（防改系统时间绕过）。
library;

import '../models/xb_domain_types.dart';

/// processing 超时阈值（R8.7.bis / F381，后端 check:traffic-exceeded 分钟级）。
const Duration kProcessingTimeout = Duration(minutes: 5);

class CheckoutService {
  /// 首次观测进入 processing 的单调计时（θ-7，按 tradeNo；防改系统时间绕过）。
  final Map<String, Stopwatch> _processingSince = {};

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
