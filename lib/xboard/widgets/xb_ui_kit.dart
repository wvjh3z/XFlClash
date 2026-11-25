/// Xboard UI kit —— 轻量「视觉反腐层」（M3 + 品牌色驱动）。
///
/// **设计意图**：封装项目高频 UI 元素的外观，让所有 Xboard 页面视觉一致 + 可被 flavor 品牌色
/// 驱动 + 满足 a11y（textScaleFactor 1.5/2.0 不溢出 / WCAG AA 对比度）。组件**自包含**（不依赖
/// FlClash 内部 widget，避免 upstream sync 破坏），全用 Material 3 原生组件 + 项目语义封装。
///
/// **形态 A 演进路径**：未来换设计语言时改本 kit 内部实现，调用方（页面）不动 —— 同反腐层隔离思想。
library;

import 'package:material_ui/material_ui.dart';

import '../config/xboard_config.dart';
import 'xb_legacy_material.dart';
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
      // Third-party HTML/QR widgets still use Flutter's bundled Material.
      // The official bridge preserves the same brand typography and locale.
      child: xbLegacyMaterial(child),
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
    this.embedded = false,
    this.maxContentWidth,
  });

  final String title;
  final Widget body;
  final Widget? bottomNavigationBar;
  final List<Widget>? actions;

  /// 桌面「面板模式」：去掉 Scaffold/AppBar（由宿主面板提供窗口 chrome 与标题/返回），
  /// 仅渲染品牌主题下的 [body]（+ 可选 [bottomNavigationBar]）。默认 false = 移动端整屏页（不变）。
  final bool embedded;

  /// 内容最大宽度（桌面宽面板下居中收窄，避免卡片拉太宽）。
  /// null = 自动：桌面（窗口宽≥600）默认居中限宽 760（表单/列表舒适阅读宽），移动端全宽。
  /// 传具体值可覆盖（如订单页双列网格用更宽）。
  final double? maxContentWidth;

  @override
  Widget build(BuildContext context) {
    // 桌面自动居中限宽（框架默认）：避免 push 子页在宽内容区被拉伸；移动端全宽不变。
    final isWide = MediaQuery.sizeOf(context).width >= 600;
    final effectiveMax = maxContentWidth ?? (isWide ? 760 : null);
    final content = effectiveMax == null
        ? body
        : Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: effectiveMax),
              child: body,
            ),
          );
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: Builder(
        builder: (context) {
          if (embedded) {
            // 面板模式：无 Scaffold/AppBar（宿主面板负责窗口 chrome / 标题 / 返回）。
            final bar = bottomNavigationBar;
            return bar == null
                ? content
                : Column(
                    children: [
                      Expanded(child: content),
                      bar,
                    ],
                  );
          }
          return Scaffold(
            appBar: AppBar(title: Text(title), actions: actions),
            body: content,
            bottomNavigationBar: bottomNavigationBar,
          );
        },
      ),
    );
  }
}

class XbGradientAction extends StatelessWidget {
  const XbGradientAction({super.key, required this.onPressed, required this.child, this.busyLabel, this.height = 46, this.padding, this.tintWhenDisabled = false, this.radius = XbTokens.rButton, this.shadow, this.keepMaterialDisabled = false});
  final VoidCallback? onPressed;
  final Widget child;
  /// An actual in-flight operation, distinct from an unavailable action.
  final String? busyLabel;
  final double height;
  final EdgeInsetsGeometry? padding;
  final bool tintWhenDisabled;
  final double radius;
  final BoxShadow? shadow;
  final bool keepMaterialDisabled;

  @override
  Widget build(BuildContext context) {
    final brand = Theme.of(context).colorScheme.primary;
    final tokens = XbTokens.of(context);
    final corners = BorderRadius.circular(radius);
    final progress = busyLabel;
    if (progress != null) {
      final fill = XbTokens.busyActionFill(brand);
      final label = Text(progress, textAlign: TextAlign.center, softWrap: true,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white));
      return FilledButton(
        onPressed: null,
        style: FilledButton.styleFrom(
          disabledBackgroundColor: fill, disabledForegroundColor: Colors.white,
          minimumSize: Size(0, height), padding: padding,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: corners), elevation: 0,
        ),
        child: label,
      );
    }
    if (onPressed == null && keepMaterialDisabled) {
      return FilledButton(onPressed: null, style: FilledButton.styleFrom(
        minimumSize: Size(0, height), padding: padding,
        shape: RoundedRectangleBorder(borderRadius: corners),
      ), child: child);
    }
    final start = brand == const Color(0xffd92e1a)
        ? const Color(0xffff5a44)
        : Color.lerp(brand, Colors.white, 0.16)!;
    final enabled = onPressed != null;
    final disabledInk = tintWhenDisabled
        ? Color.lerp(tokens.onv, tokens.on, .25)!
        : tokens.onv;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        boxShadow: enabled && shadow != null ? [shadow!] : null,
        color: tokens.sfc,
        gradient: enabled || tintWhenDisabled ? LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: enabled ? [start, brand] : [
            Color.lerp(tokens.sfc, start, .16)!,
            Color.lerp(tokens.sfc, brand, .16)!,
          ],
        ) : null,
      ),
      child: FilledButton(onPressed: onPressed, style: FilledButton.styleFrom(
        backgroundColor: Colors.transparent, foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: disabledInk,
        disabledIconColor: disabledInk,
        minimumSize: Size(0, height), padding: padding, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: corners), elevation: 0,
      ), child: DefaultTextStyle.merge(
        style: TextStyle(color: enabled ? Colors.white : disabledInk),
        child: IconTheme.merge(data: IconThemeData(color: enabled ? Colors.white : disabledInk), child: child),
      )),
    );
  }
}

String xbActionInProgress(String label) =>
    label == '提交订单' ? '正在创建订单…' : '正在$label…';

/// 品牌主按钮，加载时以不可点的动作说明替换图标与原文案。
class XbPrimaryButton extends StatelessWidget {
  const XbPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.busyLabel,
    this.icon,
  });

  final String label;

  /// null 或 loading=true 时 disabled。
  final VoidCallback? onPressed;
  final bool loading;
  final String? busyLabel;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: XbGradientAction(
        onPressed: loading ? null : onPressed,
        busyLabel: loading ? busyLabel ?? xbActionInProgress(label) : null,
        height: XbTokens.hButton,
        keepMaterialDisabled: true,
        child: Row(
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
  const XbBrandBadge({
    super.key,
    this.icon = Icons.vpn_key_rounded,
    this.size = 72,
  });

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
          colors: [
            cs.primary,
            Color.alphaBlend(cs.primary.withValues(alpha: 0.6), cs.tertiary),
          ],
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
  }) : assert(
         background == null || gradient == null,
         'background 与 gradient 互斥',
       );

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
