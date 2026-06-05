/// 形态 A 单 Tab 错误边界（spec `xboard-form-a-ui-revamp` / W1.4 / R1.7）。
///
/// **职责**：包裹每个 Tab 子树；子树渲染抛异常时显示**局部**错误态，不向上冒泡到
/// Shell / VPN 内核（单 Tab 崩不波及其它 Tab + 底栏，design 降级策略）。
///
/// **机制（Flutter 天然容错 + 友好回退）**：
/// 1. Flutter 构建期异常由 `ErrorWidget.builder` 处理，**且返回的 widget 被插入到抛异常
///    widget 的原位置**——即该 Tab 在 `IndexedStack` 的 slot 内。因此异常天然被限制在本
///    Tab 区域，Scaffold / 底栏 / 其它 Tab slot 不受影响（R1.7 核心由此满足）。
/// 2. 默认 `ErrorWidget.builder` 是全屏红屏，对单 Tab 崩溃过突兀。`XboardAppShell` 在
///    `initState` 调 [install] 换上**有界友好**回退卡（仅 formA 路径，form B 不受影响，
///    "加而不改"）。回退卡经 [XbErrorBoundaryScope] 读取所在 Tab 名。
/// 3. 本 widget 自身**不**改全局 `ErrorWidget.builder`（保持 widget test 友好：mount 本
///    widget 不污染全局错误处理）；安装由 shell 统一负责。
///
/// **适配层铁律**：纯 UI widget，不 import `lib/views/**` / FlClash internal provider。
library;

import 'package:flutter/material.dart';

/// 单 Tab 错误边界 = 向下传 Tab 名的 scope + child 透传。
///
/// 用法：`XbErrorBoundary(label: '首页', child: HomeTab())`。
/// child 构建抛异常 → Flutter 在本 Tab slot 内渲染 [install] 安装的友好错误卡，
/// 不影响其它 Tab / 底栏。
class XbErrorBoundary extends StatelessWidget {
  const XbErrorBoundary({
    super.key,
    required this.child,
    this.label,
  });

  /// 被保护的 Tab 子树。
  final Widget child;

  /// Tab 名（错误卡展示，便于定位）。
  final String? label;

  /// 安装形态 A 的有界友好 `ErrorWidget.builder`（shell `initState` 调一次）。
  ///
  /// 返回**原** builder，调用方（或测试）可在卸载时还原。幂等：重复安装同一个无副作用。
  static ErrorWidgetBuilder install() {
    final previous = ErrorWidget.builder;
    ErrorWidget.builder = friendlyErrorWidgetBuilder;
    return previous;
  }

  /// 有界友好回退卡 builder（替换默认全屏红屏）。
  static Widget friendlyErrorWidgetBuilder(FlutterErrorDetails details) =>
      const _XbErrorFallback();

  @override
  Widget build(BuildContext context) {
    // 向下传 Tab 名；错误卡（ErrorWidget.builder 产物）在本子树内经 scope 读 label。
    return XbErrorBoundaryScope(label: label, child: child);
  }
}

/// 向错误卡传递当前 Tab 名的 InheritedWidget。
class XbErrorBoundaryScope extends InheritedWidget {
  const XbErrorBoundaryScope({
    super.key,
    required this.label,
    required super.child,
  });

  final String? label;

  static String? labelOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<XbErrorBoundaryScope>()?.label;

  @override
  bool updateShouldNotify(XbErrorBoundaryScope oldWidget) =>
      label != oldWidget.label;
}

/// 局部错误回退卡（有界，不全屏红屏）。
class _XbErrorFallback extends StatelessWidget {
  const _XbErrorFallback();

  @override
  Widget build(BuildContext context) {
    // 错误卡可能脱离 MaterialApp 上下文（极端情况）；用 Material 兜底确保 Directionality / 主题。
    final scheme = Theme.of(context).colorScheme;
    final label = XbErrorBoundaryScope.labelOf(context);
    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: scheme.error),
              const SizedBox(height: 12),
              Text(
                label == null ? '页面出错了' : '「$label」出错了',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                '其它功能仍可正常使用',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
