/// 形态 A 登录/注册/忘记密码 sheet 公共外壳（spec `xboard-form-a-ui-revamp` / W5）。
///
/// 统一：可滚动（避免键盘弹出 / 长表单 overflow）、随键盘抬升、标题 + 可选 banner + 子内容。
/// 纯 UI，无 provider 依赖。
library;

import 'package:flutter/material.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';

import '../../widgets/xb_ui_kit.dart' show XbBrandTheme;

/// 弹出形态 A 风格底部 sheet（圆角 + 拖拽手柄 + 随键盘抬升 + 可滚动）。
///
/// **关键**：builder 自动包 [XbBrandTheme] —— sheet 挂根 Navigator（FlClash MaterialApp 下），
/// 不在 shell 子树内，不包则拿不到品牌主题 → 徽标/按钮退回 FlClash 灰褐色。
Future<T?> showXbBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true, // 随键盘抬升 + 内容可超过半屏
    builder: (ctx) => XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: Builder(builder: builder),
    ),
  );
}

/// sheet 内容外壳：标题 + 可选错误 banner + 子内容；随键盘 padding + 可滚动。
class XbSheetScaffold extends StatelessWidget {
  const XbSheetScaffold({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.badge,
    this.banner,
    this.footer,
  });

  final String title;
  final List<Widget> children;

  /// 可选副标题（标题下方居中小字，原型 .s2）。
  final String? subtitle;

  /// 可选品牌徽标（标题上方居中，原型 .lg）。
  final Widget? badge;

  /// 可选错误/提示 banner（非空显示）。
  final String? banner;

  /// 可选底部附加（如「没有账号？注册」）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // 标题/副标题：有徽标时整体居中（原型登录/注册风格）。
    final centered = badge != null;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (badge != null) ...[
                Center(child: badge!),
                const SizedBox(height: 13),
              ],
              Text(
                title,
                textAlign: centered ? TextAlign.center : TextAlign.start,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 5),
                Text(
                  subtitle!,
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (banner != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 18, color: scheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          banner!,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              ...children,
              if (footer != null) ...[
                const SizedBox(height: 12),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 品牌徽标（原型 .lg：渐变圆角方块 + 居中字母/图标）。登录/注册用「M」，找回密码用图标。
class XbSheetBadge extends StatelessWidget {
  const XbSheetBadge({super.key, this.letter, this.icon})
      : assert(letter != null || icon != null);

  final String? letter;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 70,
      height: 70,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(Colors.white.withValues(alpha: 0.2), scheme.primary),
            scheme.primary,
            Color.alphaBlend(Colors.black.withValues(alpha: 0.2), scheme.primary),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.5),
            blurRadius: 30,
            offset: const Offset(0, 14),
            spreadRadius: -10,
          ),
        ],
      ),
      child: letter != null
          ? Text(
              letter!,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            )
          : Icon(icon, size: 34, color: Colors.white),
    );
  }
}

/// 邮箱账号输入（前缀输入 2/3 + 后缀下拉 1/3，spec 原型布局，R5.5/R5.7）。
///
/// 后缀来自 Xboard 白名单（W0.2 emailSuffixesProvider）；空列表 = 白名单禁用 → 允许任意后缀
/// （退化为单输入框，F208）。
class XbEmailAccountField extends StatelessWidget {
  const XbEmailAccountField({
    super.key,
    required this.prefixController,
    required this.suffixes,
    required this.selectedSuffix,
    required this.onSuffixChanged,
  });

  final TextEditingController prefixController;

  /// 白名单后缀（不含 @；如 ['gmail.com','qq.com']）。空 = 白名单禁用。
  final List<String> suffixes;

  /// 当前选中后缀（含或不含 @ 由调用方约定；此处不含 @）。
  final String? selectedSuffix;

  final ValueChanged<String?> onSuffixChanged;

  @override
  Widget build(BuildContext context) {
    // 白名单禁用（空）→ 单输入框（用户自填完整邮箱）。
    if (suffixes.isEmpty) {
      return TextField(
        controller: prefixController,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(
          labelText: '邮箱账号',
          prefixIcon: Icon(Icons.email_outlined),
        ),
      );
    }
    // 前缀 2/3 + 后缀下拉 1/3。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: TextField(
            controller: prefixController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: '邮箱账号',
              prefixIcon: Icon(Icons.email_outlined),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 1,
          child: DropdownButtonFormField<String>(
            initialValue: selectedSuffix ?? suffixes.first,
            isExpanded: true,
            decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 16)),
            items: [
              for (final s in suffixes)
                DropdownMenuItem(value: s, child: Text('@$s', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: onSuffixChanged,
          ),
        ),
      ],
    );
  }
}

/// 验证码输入（短输入框 + 获取按钮并排，R5.8）。
class XbVerifyCodeField extends StatelessWidget {
  const XbVerifyCodeField({
    super.key,
    required this.controller,
    required this.cooldownSeconds,
    required this.onSend,
  });

  final TextEditingController controller;

  /// 冷却剩余秒（>0 时按钮禁用 + 显示倒计时）。
  final int cooldownSeconds;

  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          flex: 2,
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: '验证码',
              counterText: '',
              prefixIcon: Icon(Icons.verified_outlined),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 1,
          child: OutlinedButton(
            onPressed: cooldownSeconds > 0 ? null : onSend,
            child: Text(
              cooldownSeconds > 0 ? '${cooldownSeconds}s' : '获取',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}
