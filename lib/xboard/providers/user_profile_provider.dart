/// R6 账号订阅数据 provider（design 状态管理表 = 唯一权威）。
///
/// **职责**：调反腐层 `getSubscription()`（getSubscribe 单端点 D27）拉账号订阅信息。
///
/// **keepAlive + Property 21**：keepAlive（不随 UI 重建丢数据）；endpoint 变化**不**自动
/// invalidate（Property 21：endpoint 热替换不重建已加载 UI），仅主动 `refresh()` / 下拉刷新
/// （R6.4）才重发。
///
/// **F14 防御（design L1467）**：调用方 UI 必须先 gate `authState == authenticated` 再 watch
/// 本 provider —— 游客态不应触发 getSubscription（会撞 R10 banner 误弹「登录已过期」）。
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/xb_domain_subscription.dart';
import '../models/xb_result.dart';
import 'xboard_providers.dart';

part '../generated/providers/user_profile_provider.g.dart';

/// 账号订阅信息（R6）。success → 数据；failure → 抛 XbDomainError（UI 经 AsyncValue.error
/// 用 XboardStateView 分流，error 态按 7 子类型渲染）。
///
/// keepAlive：登录态期间常驻；logout / 切账号时调用方 `ref.invalidate` 清。
@Riverpod(keepAlive: true)
Future<XbDomainSubscription> userProfile(Ref ref) async {
  final result = await ref.watch(xboardServiceProvider).getSubscription();
  return switch (result) {
    XbSuccess(:final data) => data,
    XbFailure(:final error) => throw error, // AsyncError → UI XboardStateView 分流
  };
}
