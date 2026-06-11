/// 形态 A 动效地基（motion tokens + 复用动效组件）。
///
/// **设计意图**：把全 App 动效的「时长 / 缓动 / 无障碍降级」统一到一处,做成可复用组件,
/// 避免每处各写一套导致节奏乱、廉价感(专业动效原则:少而精、统一节奏)。
///
/// **无障碍铁律**：尊重系统「减弱动态效果」(`MediaQuery.disableAnimations`,iOS Reduce Motion /
/// Android 移除动画)。开启时持续/强动效降级为瞬切或淡入。各组件内部已处理。
///
/// **golden 安全**：本文件提供的都是**有限(一次性)动画**(TweenAnimationBuilder / AnimatedScale),
/// 会被 `pumpAndSettle` 收敛到终态;**不在 golden 屏用循环动画**(那会让 pumpAndSettle 卡死)。
library;

import 'package:flutter/material.dart';

/// 动效 token：统一时长 + 缓动曲线。
class XbMotion {
  XbMotion._();

  // —— 时长（三档,对齐通用动效规范）——
  static const Duration fast = Duration(milliseconds: 150); // 微交互(按压/选中)
  static const Duration base = Duration(milliseconds: 240); // 常规过渡(状态/淡入)
  static const Duration slow = Duration(milliseconds: 420); // 大过渡(页面/计数)

  // —— 缓动 ——
  static const Curve standard = Curves.easeOutCubic; // 标准减速
  static const Curve emphasized = Curves.easeOutBack; // 带回弹(成功/选中强调)
  static const Curve decelerate = Curves.fastOutSlowIn; // 进入

  /// 系统是否要求减弱动态效果(无障碍)。true → 动效应降级。
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// 按压缩放反馈：包裹任意可点 widget,按下时轻微缩小(scale≈0.96)+ 回弹。
///
/// 用于卡片 / 列表行 / 自定义按钮等没有 Material ripple 的可点区域(FilledButton 等已自带
/// ripple,无需再包)。reduce-motion 时不缩放,仅保留点击。
class XbPressable extends StatefulWidget {
  const XbPressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.96,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 按下时缩放比例(默认 0.96)。
  final double scale;

  /// 可选圆角(用于点击高亮裁剪,当前仅缩放,预留)。
  final BorderRadius? borderRadius;

  @override
  State<XbPressable> createState() => _XbPressableState();
}

class _XbPressableState extends State<XbPressable> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap == null) return;
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = XbMotion.reduced(context);
    final pressed = _down && !reduced;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: AnimatedScale(
        scale: pressed ? widget.scale : 1.0,
        duration: XbMotion.fast,
        curve: XbMotion.standard,
        child: widget.child,
      ),
    );
  }
}

/// 数字滚动(count-up)：值变化时从旧值平滑滚动到新值,而非跳变。
///
/// 动画原始 [value](double),通过 [builder] 把当前帧的插值交给调用方格式化(单位/精度自定)。
/// reduce-motion 时直接显示目标值(零时长)。一次性动画(golden 安全:settle 到终值)。
class XbCountUp extends StatelessWidget {
  const XbCountUp({
    super.key,
    required this.value,
    required this.builder,
    this.duration = XbMotion.slow,
    this.curve = XbMotion.standard,
  });

  /// 目标值(变化即触发从当前显示值滚动到它)。
  final double value;

  /// 用当前帧插值构建内容(如格式化成 "68.5 Mbps")。
  final Widget Function(BuildContext context, double animatedValue) builder;

  final Duration duration;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    final reduced = XbMotion.reduced(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value),
      duration: reduced ? Duration.zero : duration,
      curve: curve,
      builder: (context, v, _) => builder(context, v),
    );
  }
}
