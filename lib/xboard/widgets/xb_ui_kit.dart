/// Xboard UI kit —— 轻量「视觉反腐层」（M3 + 品牌色驱动）。
///
/// **设计意图**：封装项目高频 UI 元素的外观，让所有 Xboard 页面视觉一致 + 可被 flavor 品牌色
/// 驱动 + 满足 a11y（textScaleFactor 1.5/2.0 不溢出 / WCAG AA 对比度）。组件**自包含**（不依赖
/// FlClash 内部 widget，避免 upstream sync 破坏），全用 Material 3 原生组件 + 项目语义封装。
///
/// **形态 A 演进路径**：未来换设计语言时改本 kit 内部实现，调用方（页面）不动 —— 同反腐层隔离思想。
library;

import 'package:flutter/material.dart';

/// 品牌色叠加：在 Xboard 页面树根部用 flavor brandColor 局部覆盖 seedColor，
/// 让「我的服务」区域呈现品牌色但组件仍是 M3（与 FlClash 底座视觉协调）。
///
/// **🔴 配色策略（品牌强调 + 中性底）**：
/// M3 `fromSeed` 会把**所有**色（含表面/文字/填充）按种子色调和——品牌红会把输入框填充染成
/// 粉红 `#fbdcd6`、次要文字染成浑浊棕 `#5c403b`，整体「发脏」。
/// 解法：**双 scheme 合并**——
/// - 品牌色（fidelity）只供「强调色族」：primary / onPrimary / secondary / tertiary / error 等；
/// - 中性灰（neutral 变体，灰种子）供「中性色族」：surface* / onSurface* / outline* 等。
/// 结果：按钮/徽标/链接/焦点框是品牌红，输入框填充与正文/次要文字是干净的中性灰。
///
/// 关键交互元素（主按钮、徽标）再由 [XbPrimaryButton]/[XbBrandBadge] 用品牌本色直出。
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
    final base = Theme.of(context);
    final brightness = base.brightness;
    final isLight = brightness == Brightness.light;

    // 强调色族：忠于品牌色。
    final brand = ColorScheme.fromSeed(
      seedColor: brandColor,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );

    // 🔴 中性底色族：**硬钉原型 token**（不走 M3 算法，避免掺入品牌红色相导致背景泛暖粉）。
    // 原型 full.html CSS 变量（:root 浅色 / .screen.dark 深色），1:1 映射到 M3 surface 角色。
    final n = isLight ? _XbNeutral.light : _XbNeutral.dark;

    // 合并：品牌出强调，中性出底。primary 锁品牌本色（#d92e1a 配白字 4.82:1 过 WCAG AA）。
    final scheme = brand.copyWith(
      primary: brandColor,
      onPrimary: Colors.white,
      // 中性色族整体硬钉（原型固定值，无品牌色相）。
      surface: n.sf, // --sf：页面/scaffold 背景
      onSurface: n.on, // --on：正文
      onSurfaceVariant: n.onv, // --onv：次要文字
      surfaceContainerLowest: n.card, // --card/--sf2：卡片/orb核心/sheet（最白）
      surfaceContainerLow: n.card, // 卡片底
      surfaceContainer: n.sfc, // --sfc：分段槽/chip
      surfaceContainerHigh: n.sfc, // 输入框填充
      surfaceContainerHighest: n.sfc, // 轨道环底
      outline: n.line, // --line：边框
      outlineVariant: n.line, // --line：细分隔
      inverseSurface: n.on,
      onInverseSurface: n.sf,
    );

    // 链接文字色：用品牌的**较深色调**（fidelity primary，浅色 #b50e00 对比度 6.58:1），
    // 既明显是「品牌可点链接」，又比纯亮红 #d92e1a（4.57:1）更耐看不刺眼。
    final linkColor = brand.primary;

    return Theme(
      data: base.copyWith(
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        // 链接/文字按钮：用较深品牌色，清晰可点且不刺眼。
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: linkColor,
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      child: child,
    );
  }
}

/// 原型中性底色 token（full.html CSS `:root` / `.screen.dark`）。
/// 硬钉值（不走 M3 算法），保证背景是干净中性灰、不泛品牌色相。
class _XbNeutral {
  const _XbNeutral({
    required this.sf,
    required this.sf2,
    required this.card,
    required this.sfc,
    required this.on,
    required this.onv,
    required this.line,
    required this.hair,
  });

  final Color sf; // 页面背景 --sf
  final Color sf2; // 纯白面 --sf2
  final Color card; // 卡片 --card
  final Color sfc; // 容器/分段槽 --sfc
  final Color on; // 正文 --on
  final Color onv; // 次要文字 --onv
  final Color line; // 边框 --line
  final Color hair; // 细线 --hair

  static const light = _XbNeutral(
    sf: Color(0xFFF5F6F8),
    sf2: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    sfc: Color(0xFFEEF0F4),
    on: Color(0xFF11141B),
    onv: Color(0xFF6A7180),
    line: Color(0xFFE9ECF1),
    hair: Color(0xFFF0F2F5),
  );

  static const dark = _XbNeutral(
    sf: Color(0xFF0A0C11),
    sf2: Color(0xFF13161D),
    card: Color(0xFF13161D),
    sfc: Color(0xFF171A22),
    on: Color(0xFFF1F3F8),
    onv: Color(0xFF8990A2),
    line: Color(0xFF23262F),
    hair: Color(0xFF1A1D25),
  );
}

/// 主按钮 —— loading 态内嵌 spinner（R1.7/R2.7 复用），M3 FilledButton。
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
      height: 52,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
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

/// 文本输入 —— 带 errorText 红框（复用 validationErrors 渲染）、圆角填充、前置图标。
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
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      enabled: enabled,
      autofillHints: autofillHints,
      style: TextStyle(color: cs.onSurface, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: cs.onSurfaceVariant),
        floatingLabelStyle: TextStyle(color: cs.primary),
        errorText: errorText,
        prefixIcon: prefixIcon != null
            ? Icon(prefixIcon, color: cs.onSurfaceVariant, size: 22)
            : null,
        suffixIcon: suffix,
        filled: true,
        // 干净中性灰填充（中性 scheme 提供，不带品牌色调）。
        fillColor: cs.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary, width: 1.8),
        ),
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
