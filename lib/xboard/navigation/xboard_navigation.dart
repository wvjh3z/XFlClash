/// Xboard 主导航注入（接缝点 #6 / 决策 #8 / DD-7 / F396）。
///
/// **接缝点 #6**：`lib/common/navigation.dart::getItems()` 返回 list 末尾 spread
/// `...XboardNavigation.items`（仅 1 行，加而不改）。
///
/// **决策 #8（b）**：NavigationItem 的 `label` 是强类型 `PageLabel` enum（8 值，upstream
/// 无 `xboard`）。方案 (a) patch upstream enum 每次 sync 都是债；方案 (b) 用 `PageLabel.dashboard`
/// **占位**，由 `XboardServiceHomePage` / 导航渲染分支**自渲染标题**（不挂 PageLabel 名 → arb key
/// 反射链路），DD-7 兑现「Tab 标题不挂 FlClash PageLabel」。
///
/// FlClash 用 `Intl.message(item.label.name)` 反射 enum 名取 arb key（home.dart / app_manager.dart /
/// tools.dart）。`XboardNavigation.intercept(item)` 判别命中 Xboard 项 → 切换为自渲染中文标题
/// （v0.1 仅简体中文 D15）；具体拦截点 W3+ 按实测接入（当前占位）。
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
      // 决策 #8(b)：PageLabel.dashboard 占位，标题由 intercept/页面自渲染（不走 enum→arb）。
      label: PageLabel.dashboard,
      builder: (_) => const XboardServiceHomePage(),
      modes: const [NavigationItemMode.mobile, NavigationItemMode.desktop],
    ),
  ];

  /// 判别某 NavigationItem 是否为 Xboard 注入项（用于渲染分支切换自渲染标题，决策 #8(b)）。
  ///
  /// 用 builder 引用相等判别（`items` 是 static final，`getItems()` spread 的是同一元素引用）。
  /// W3+ 在 home.dart / app_manager.dart 渲染分支按实测接入；当前提供判别函数占位。
  static bool isXboardItem(NavigationItem item) =>
      items.any((x) => identical(x.builder, item.builder));

  /// Xboard 项的自渲染标题（v0.1 仅简体中文，D15）。
  static String titleOf(NavigationItem item) => '我的服务';
}
