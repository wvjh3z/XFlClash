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
/// **🔴 配色保真（fidelity）**：M3 默认 `tonalSpot` 变体会把鲜艳品牌色去饱和调和
/// （如 `#d92e1a` → 棕红 `#904b3f`），偏离品牌视觉。这里用 `DynamicSchemeVariant.fidelity`
/// 让生成的配色**忠于品牌色**（primaryContainer 精确还原种子色），同时保留 M3 对比度体系。
/// 关键交互元素（主按钮、徽标）再由 [XbPrimaryButton]/[XbBrandBadge] 用品牌本色直出，
/// 确保「就是那个红」。
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
    final seeded = ColorScheme.fromSeed(
      seedColor: brandColor,
      brightness: base.brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    // primary 锁定品牌本色（保证「就是那个红」）；onPrimary 取白
    // （#d92e1a 配白字对比度 4.82:1，过 WCAG AA）。容器/表面色仍由 fidelity 调和。
    final scheme = seeded.copyWith(
      primary: brandColor,
      onPrimary: Colors.white,
    );
    return Theme(
      data: base.copyWith(colorScheme: scheme),
      child: child,
    );
  }
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
        prefixIcon: prefixIcon != null ? Icon(prefixIcon) : null,
        suffixIcon: suffix,
        filled: true,
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
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 1.6,
          ),
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
