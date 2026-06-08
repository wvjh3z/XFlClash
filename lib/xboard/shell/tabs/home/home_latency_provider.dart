/// 首页延迟独立状态（spec `xboard-form-a-ui-revamp` / W3.2）。
///
/// **为什么独立**：首页速度卡的延迟**不读节点列表的全局延迟表**（`delayProvider`，那是节点页
/// 各节点各 testUrl 的历史值，口径/时机不一致）。首页延迟只反映「连接时 / 已连接切换节点时」
/// 由 `measureCurrentNodeBest`（3 次取最低）现测的结果，独立持有，互不干扰。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 首页延迟状态。
class HomeLatencyState {
  const HomeLatencyState({this.ms, this.measuring = false});

  /// 最近一次测得的延迟（ms，>0 有效）；null = 尚未测 / 测速失败。
  final int? ms;

  /// 是否正在测速（连接/切换后触发，UI 可显示「测速中」）。
  final bool measuring;

  HomeLatencyState copyWith({int? ms, bool? measuring, bool clearMs = false}) =>
      HomeLatencyState(
        ms: clearMs ? null : (ms ?? this.ms),
        measuring: measuring ?? this.measuring,
      );
}

/// 首页延迟 Notifier：测速开始/结束驱动速度卡显示。
class HomeLatencyNotifier extends Notifier<HomeLatencyState> {
  @override
  HomeLatencyState build() => const HomeLatencyState();

  /// 开始测速：置 measuring=true（保留上次 ms，避免闪烁；UI 可据 measuring 显示转圈）。
  void startMeasuring() {
    state = state.copyWith(measuring: true);
  }

  /// 测速结束：写入结果（[ms] 为 null/<=0 表示失败 → 清空显示）。
  void setResult(int? ms) {
    state = (ms != null && ms > 0)
        ? HomeLatencyState(ms: ms, measuring: false)
        : const HomeLatencyState(ms: null, measuring: false);
  }

  /// 重置（如断开连接 / 退登）。
  void reset() {
    state = const HomeLatencyState();
  }
}

/// 首页延迟 provider。
final homeLatencyProvider =
    NotifierProvider<HomeLatencyNotifier, HomeLatencyState>(
  HomeLatencyNotifier.new,
);
