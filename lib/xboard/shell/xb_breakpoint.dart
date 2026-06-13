/// 形态 A 桌面/移动断点判定（spec `xboard-form-a-ui-revamp` 桌面适配 / C-分支地基）。
///
/// **为什么用宽度而非 `Platform.isDesktop`**：窗口缩放、平板、分屏都应按「可用宽度」
/// 决定单列还是双栏/左侧栏，而不是按操作系统。桌面窗口拖窄也应回退移动端排布。
///
/// **适配层铁律**：纯 layout helper，不 import `lib/views/**` / FlClash internal provider。
library;

import 'package:flutter/widgets.dart';

/// 形态 A 布局断点（逻辑像素宽度）。
class XbBreakpoint {
  XbBreakpoint._();

  /// ≥ 此宽度 → 桌面布局（左侧导航栏 + 双栏内容）；否则移动端（底栏 + 单列）。
  ///
  /// 900 是常见「平板横屏 / 小桌面窗口」的分界；低于它单列体验更好。
  static const double desktopMinWidth = 900;

  /// 当前是否走桌面布局（看可用宽度，不看操作系统）。
  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktopMinWidth;

  /// 当前是否走移动端布局。
  static bool isMobile(BuildContext context) => !isDesktop(context);
}
