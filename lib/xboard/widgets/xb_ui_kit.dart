/// Xboard UI kit —— 轻量「视觉反腐层」（M3 + 品牌色驱动）。
///
/// **设计意图**：封装项目高频 UI 元素的外观，让所有 Xboard 页面视觉一致 + 可被 flavor 品牌色
/// 驱动 + 满足 a11y（textScaleFactor 1.5/2.0 不溢出 / WCAG AA 对比度）。组件**自包含**（不依赖
/// FlClash 内部 widget，避免 upstream sync 破坏），全用 Material 3 原生组件 + 项目语义封装。
///
/// **形态 A 演进路径**：未来换设计语言时改本 kit 内部实现，调用方（页面）不动 —— 同反腐层隔离思想。
library;

import 'package:flutter/material.dart';

import '../config/xboard_config.dart';
import 'xb_theme.dart';

/// 形态 A 品牌主题注入点（薄封装，真源 = [buildXbTheme]）。
///
/// **唯一职责**：在子树根部注入 [buildXbTheme] 生成的完整 ThemeData（品牌强调 + 原型中性底
/// + 全组件子主题）。设计语言改动只动 `xb_theme.dart`，本类不变。
///
/// **作用域三处**：① shell body（`XboardAppShell`）② sheet 入口（`showXbBottomSheet` 内部）
/// ③ 页面 push 入口（`xbPush`）—— 确保挂根 Navigator 的 sheet/页面也吃到主题。
class XbBrandTheme extends StatelessWidget {
  const XbBrandTheme({
    super.key,
    required this.brandColor,
    required this.child,
  });

  final Color brandColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildXbTheme(
        brandColor: brandColor,
        brightness: Theme.of(context).brightness,
      ),
      child: child,
    );
  }
}

/// 形态 A 品牌脚手架页 —— `XbBrandTheme + Builder + Scaffold + AppBar` 一站封装。
///
/// **设计意图**：所有 push 二级页都手写同一套包裹（注品牌色 → Builder → Scaffold → AppBar 标题），
/// 重复 5 处。本组件收口：传 [title] + [body]（+ 可选 [bottomNavigationBar]），自动注品牌主题。
/// 改页面脚手架（如统一 appbar 行为）只动这一处。
class XbBrandScaffold extends StatelessWidget {
  const XbBrandScaffold({
    super.key,
    required this.title,
    required this.body,
    this.bottomNavigationBar,
    this.actions,
  });

  final String title;
  final Widget body;
  final Widget? bottomNavigationBar;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(title), actions: actions),
          body: body,
          bottomNavigationBar: bottomNavigationBar,
        ),
      ),
    );
  }
}

/// 主按钮 —— loading 态内嵌 spinner。样式全吃主题 `filledButtonTheme`（品牌红/圆角/高52）。
class XbPrimaryButton extends StatelessWidget {
  const XbPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
  });

  final String label;

  /// null 或 loading=true 时 disabled。
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        child: loading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: cs.onPrimary,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20),
                    const SizedBox(width: 8),
                  ],
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
                ],
              ),
      ),
    );
  }
}

/// 文本输入 —— 样式全吃主题 `inputDecorationTheme`（填充/圆角/聚焦品牌边）。
class XbTextField extends StatelessWidget {
  const XbTextField({
    super.key,
    required this.label,
    this.controller,
    this.errorText,
    this.prefixIcon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.suffix,
    this.enabled = true,
    this.autofillHints,
  });

  final String label;
  final TextEditingController? controller;
  final String? errorText;
  final IconData? prefixIcon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;
  final bool enabled;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      enabled: enabled,
      autofillHints: autofillHints,
      decoration: InputDecoration(
        labelText: label,
        errorText: errorText,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 22) : null,
        suffixIcon: suffix,
      ),
    );
  }
}

/// 品牌图标徽标 —— 渐变圆角容器 + 居中图标（登录/注册页头部用）。
class XbBrandBadge extends StatelessWidget {
  const XbBrandBadge({super.key, this.icon = Icons.vpn_key_rounded, this.size = 72});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary, Color.alphaBlend(cs.primary.withValues(alpha: 0.6), cs.tertiary)],
        ),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withValues(alpha: 0.32),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Icon(icon, size: size * 0.5, color: cs.onPrimary),
    );
  }
}

/// 方形图标徽标 —— 「固定尺寸正方形 + 圆角 + 居中图标」基元（批次三视觉收敛）。
///
/// **背景**：设置项 / 信息卡 / 续费头 / 登录卡等 7+ 处各自手写
/// `Container(width:s,height:s, decoration: BoxDecoration(color/gradient, borderRadius), child: Icon)`。
/// 容器壳子重复，但配方各异（品牌淡底 / 中性灰底 / 品牌渐变实底，尺寸 40/42，圆角 10/12/16）。
/// 本组件**只收敛容器骨架**——背景色 / 渐变 / 尺寸 / 圆角 / 图标色全参数透传，**像素严格不变**，
/// 调用点从约 10 行降为 1 行。不引入 variant 枚举（配方差异是设计有意，不强行统一）。
class XbIconBadge extends StatelessWidget {
  const XbIconBadge({
    super.key,
    required this.icon,
    this.size = 42,
    this.radius = XbTokens.rMd,
    this.background,
    this.gradient,
    this.iconColor,
    this.iconSize,
  }) : assert(background == null || gradient == null,
            'background 与 gradient 互斥');

  /// 图标。
  final IconData icon;

  /// 正方形边长。
  final double size;

  /// 圆角半径。
  final double radius;

  /// 纯色背景（与 [gradient] 互斥）。
  final Color? background;

  /// 渐变背景（与 [background] 互斥，如品牌渐变实底）。
  final Gradient? gradient;

  /// 图标颜色。
  final Color? iconColor;

  /// 图标尺寸（默认 size 的一半）。
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: gradient == null ? background : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, size: iconSize ?? size * 0.5, color: iconColor),
    );
  }
}
