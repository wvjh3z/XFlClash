/// 形态 A 原生页适配器（spec `xboard-form-a-ui-revamp` / W2.5 / R6.8）。
///
/// **职责（风险②b 收口）**：把「从自定义壳 push FlClash 原生页」收口。形态 A「我的 → 设置」
/// 直接复用 FlClash 原生 `ToolsView`（脱离 HomePage 外壳单独 push，PoC 已验证可渲染）。
/// Tab 不直接 import `lib/views/tools.dart`，经本适配器。
library;

import 'package:fl_clash/views/tools.dart' show ToolsView;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 原生页适配器。
class XbNativePageAdapter {
  const XbNativePageAdapter();

  /// push 原生设置页（FlClash `ToolsView`）。
  ///
  /// 用 `Navigator.push`（MaterialPageRoute）脱壳单独 push（PoC R4 已验证渲染不崩）。
  Future<void> openTools(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ToolsView()),
    );
  }
}

/// 原生页适配器单例 provider（Tab 经此取，测试可 override）。
final xbNativePageAdapterProvider = Provider<XbNativePageAdapter>(
  (ref) => const XbNativePageAdapter(),
);
