/// 分享落地页地址 provider（form-a 分享好友 + 邀请返佣页共用）。
///
/// **免登录**：ShareLink 是 guest 接口，游客态也可调（SDK 已 initialize 即可，无需 token）。
/// **手写 provider**：调反腐层 `getShareLink()`，永不抛——失败经 AsyncError 由 UI 分流。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_invite.dart';
import '../models/xb_result.dart';
import 'xboard_providers.dart';

/// 分享落地页地址（主/备）。autoDispose：进页拉、离页回收。
///
/// 成功且 `enabled=false`（后台关闭/未配置）也是 data 态（非 error）——UI 据 enabled 显示未配置态。
final shareLinkProvider = FutureProvider.autoDispose<XbShareLink>((ref) async {
  final result = await ref.watch(xboardServiceProvider).getShareLink();
  return switch (result) {
    XbSuccess(:final data) => data,
    XbFailure(:final error) => throw error,
  };
});
