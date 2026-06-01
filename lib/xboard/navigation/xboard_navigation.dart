/// Xboard 主导航注入（接缝点 #6 / 决策 #8 / DD-7 / F396）。
///
/// **接缝点 #6**：`lib/common/navigation.dart::getItems()` 返回 list 末尾 spread
/// `...XboardNavigation.items`（仅 1 行，加而不改）。
///
/// **决策 #8（a 修订）**：NavigationItem 的 `label` 是强类型 `PageLabel` enum，且被 FlClash
/// 用作**全局唯一页面寻址 key**（`currentPageLabelProvider` + `indexWhere(label==pageLabel)`）。
/// 原方案 (b) 复用 `PageLabel.dashboard` 占位 → 两项同 label，路由冲突（点本项却渲染原生
/// dashboard）+ 标题串成"仪表盘"。修订为方案 (a)：上游 enum 加专属 `PageLabel.xboard`（接缝点
/// #6.bis，PATCHES 登记），根治唯一寻址。
///
/// **标题自渲染**：FlClash 用 `Intl.message(item.label.name)` 反射 enum 名取 arb key。
/// `PageLabel.xboard` 无对应 arb key，故 home.dart（mobile）/ app_manager.dart（desktop）的
/// 标题渲染处接 `isXboardItem(e) ? titleOf(e) : Intl.message(e.label.name)` 分支，
/// Xboard 项走 [titleOf] 自渲染中文「我的服务」（v0.1 仅简体中文 D15）。
library;

import 'package:flutter/material.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/common.dart';

import '../pages/xboard_service_home_page.dart';

/// Xboard 注入的导航项集合（v0.1 仅「我的服务」1 项）。
abstract final class XboardNavigation {
  /// v0.1 注入的导航项：「我的服务」主 Tab（mobile + desktop 双形态）。
  static final List<NavigationItem> items = [
    NavigationItem(
      icon: const Icon(Icons.account_circle),
      // 决策 #8(a 修订)：用专属 PageLabel.xboard 唯一寻址（不再复用 dashboard 占位）；
      // 标题由 home.dart / app_manager.dart 的 isXboardItem 分支自渲染（不走 enum→arb）。
      label: PageLabel.xboard,
      builder: (_) => const XboardServiceHomePage(),
      modes: const [NavigationItemMode.mobile, NavigationItemMode.desktop],
    ),
  ];

  /// 判别某 NavigationItem 是否为 Xboard 注入项（标题渲染分支用，决策 #8(a)）。
  ///
  /// 用 `label == PageLabel.xboard` 判别（专属唯一 label，不再依赖 builder 引用相等）。
  static bool isXboardItem(NavigationItem item) =>
      item.label == PageLabel.xboard;

  /// Xboard 项的自渲染标题（v0.1 仅简体中文，D15）。
  static String titleOf(NavigationItem item) => '我的服务';
}
