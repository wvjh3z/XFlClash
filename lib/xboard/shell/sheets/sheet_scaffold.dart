/// 形态 A 登录/注册/忘记密码 sheet 公共外壳（spec `xboard-form-a-ui-revamp` / W5）。
///
/// 统一：可滚动（避免键盘弹出 / 长表单 overflow）、随键盘抬升、标题 + 可选 banner + 子内容。
/// 纯 UI，无 provider 依赖。
library;

import 'package:flutter/material.dart';

/// 弹出形态 A 风格底部 sheet（圆角 + 拖拽手柄 + 随键盘抬升 + 可滚动）。
Future<T?> showXbBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true, // 随键盘抬升 + 内容可超过半屏
    showDragHandle: true,
    builder: builder,
  );
}

/// sheet 内容外壳：标题 + 可选错误 banner + 子内容；随键盘 padding + 可滚动。
class XbSheetScaffold extends StatelessWidget {
  const XbSheetScaffold({
    super.key,
    required this.title,
    required this.children,
    this.banner,
    this.footer,
  });

  final String title;
  final List<Widget> children;

  /// 可选错误/提示 banner（非空显示）。
  final String? banner;

  /// 可选底部附加（如「没有账号？注册」）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
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
              const SizedBox(height: 16),
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
