/// 形态 A 布局适配器（spec `xboard-form-a-ui-revamp` / C-分支响应式 gate 收口）。
///
/// 把 FlClash 响应式 `isMobileViewProvider`（按窗口宽度判定 mobile/desktop 视图）收口到
/// xboard 适配层 —— shell / tabs **不直接** import FlClash internal provider（适配层铁律），
/// 一律改 watch 本 provider。
///
/// - 窄窗口（手机 / 桌面小窗）→ `true` → 移动端 PageView + 底栏外壳。
/// - 宽窗口（桌面常规）→ `false` → 桌面 NavRail + IndexedStack 外壳（win / mac / linux 通用）。
///
/// 用响应式宽度而非平台判定：桌面把窗口拖到很窄也能优雅退化成移动端外壳（与 FlClash 自身
/// 响应式语义一致，desktop_gate_test 即 override 此 provider）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/providers/app.dart' show isMobileViewProvider;

/// 形态 A 响应式 gate：转发 FlClash `isMobileViewProvider`。
///
/// `true` = 移动端视图（窄）；`false` = 桌面视图（宽，走左侧 NavRail 外壳）。
final xbIsMobileViewProvider = Provider<bool>(
  (ref) => ref.watch(isMobileViewProvider),
);
