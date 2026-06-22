/// 邀请返佣 providers（form-a 邀请功能）。
///
/// **手写 provider**（与 codegen provider 共存）：调反腐层 `XboardService`，永不抛——
/// 失败经 `AsyncValue.error(XbDomainError)` 由 UI 的 [XbAsyncView] 分流（error 态重试）。
///
/// **gate**：调用方页面须在已登录态进入（邀请功能需 token）；`xboardServiceProvider` 在 SDK
/// 未就绪时抛 StateError（UI 应先 gate bootstrapReady + authenticated）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_invite.dart';
import '../models/xb_result.dart';
import 'xboard_providers.dart';

/// 邀请返佣汇总（autoDispose：进页拉、离页回收，下拉刷新用 invalidate）。
///
/// **无邀请码自动生成**（原型决策）：首拉若 `!hasCode`，自动调 `generateInviteCode()` 后重拉一次；
/// 生成失败不阻塞（沿用无码态，UI 仍可展示统计 / 引导）。
final inviteInfoProvider = FutureProvider.autoDispose<XbInviteInfo>((ref) async {
  final service = ref.watch(xboardServiceProvider);
  final result = await service.getInviteInfo();
  var info = switch (result) {
    XbSuccess(:final data) => data,
    XbFailure(:final error) => throw error, // → AsyncError，UI XbAsyncView 分流
  };
  if (!info.hasCode) {
    final gen = await service.generateInviteCode();
    if (gen is XbSuccess<String>) {
      final reload = await service.getInviteInfo();
      if (reload is XbSuccess<XbInviteInfo>) info = reload.data;
    }
  }
  return info;
});

/// 返佣记录（首页 50 条；记录页用）。autoDispose：进页拉、离页回收。
final commissionRecordsProvider =
    FutureProvider.autoDispose<List<XbCommissionRecord>>((ref) async {
  final result =
      await ref.watch(xboardServiceProvider).getCommissionRecords(pageSize: 50);
  return switch (result) {
    XbSuccess(:final data) => data,
    XbFailure(:final error) => throw error,
  };
});

/// 提现收款方式白名单（后端 `/api/v1/user/comm/config`）。
///
/// autoDispose：随提现弹窗所在页进/离。失败或空 → 返空列表（**不抛**），UI 侧回退到本地默认
/// 白名单 `kWithdrawMethods`（提现弹窗只在已配置时才更有意义，但接口不可用不应阻断提现入口）。
final withdrawConfigProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  final result = await ref.watch(xboardServiceProvider).getWithdrawMethods();
  return switch (result) {
    XbSuccess(:final data) => data,
    XbFailure() => const <String>[],
  };
});

/// 同步暴露收款方式列表给提现弹窗（未就绪 / 失败 → 空，UI 回退 `kWithdrawMethods`）。
///
/// 拆出同步 `Provider` 是为让弹窗的 `_methods` getter 直接拿 `List<String>`（无需在 getter 里处理
/// AsyncValue），保持下拉构建简单；底层异步拉取仍由 [withdrawConfigProvider] 负责。
final withdrawMethodsProvider = Provider.autoDispose<List<String>>((ref) {
  return ref.watch(withdrawConfigProvider).asData?.value ?? const <String>[];
});
