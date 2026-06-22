/// 使用教程 provider（form-a 使用教程功能）。
///
/// **需登录**：知识库是 user 接口（带 token）；菜单入口仅登录态可见，故此处不再判空。
/// **手写 provider**：调反腐层 `getTutorials()` / `getTutorialDetail(id)`，失败经 AsyncError 由 UI 分流。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_result.dart';
import '../models/xb_tutorial.dart';
import 'xboard_providers.dart';

/// 使用教程列表（后端知识库「官方客户端」分类）。autoDispose：进页拉、离页回收。
///
/// 成功但空（该分类无文章）也是 data 态（非 error）——UI 据空列表显示空态。
final tutorialsProvider =
    FutureProvider.autoDispose<List<XbTutorial>>((ref) async {
  final result = await ref.watch(xboardServiceProvider).getTutorials();
  return switch (result) {
    XbSuccess(:final data) => data,
    XbFailure(:final error) => throw error,
  };
});

/// 单篇教程详情（按文章 id）。family + autoDispose：进详情页拉、离页回收。
final tutorialDetailProvider =
    FutureProvider.autoDispose.family<XbTutorialDetail, int>((ref, id) async {
  final result = await ref.watch(xboardServiceProvider).getTutorialDetail(id);
  return switch (result) {
    XbSuccess(:final data) => data,
    XbFailure(:final error) => throw error,
  };
});
