/// 形态 A 通用反馈助手（toast / 确认对话框 / 品牌色取值）。
///
/// **设计意图**：`_toast` 私有方法逐字复制在 5 处、确认对话框样板在 4 处、
/// `Color(XboardConfig.current.brandColor)` 散取在 9+ 处。集中到此，改一处全改。
library;

import 'package:flutter/material.dart';

import '../config/xboard_config.dart';
import 'xb_theme.dart' show xbShowDialog, XbTokens;

/// 当前 flavor 品牌色（替代散落的 `Color(XboardConfig.current.brandColor)`）。
Color xbBrandColor() => Color(XboardConfig.current.brandColor);

/// 轻提示（SnackBar）—— 替代各页逐字复制的私有 `_toast`。
/// 内部用根 messenger，避免 sheet/dialog pop 后 context 失效丢提示。
void xbToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// 二次确认对话框（取消订单 / 退出登录 等）—— 统一标题/内容/取消·确认两键。
///
/// [destructive] = true 时确认键用 destructive 红（不可逆操作，如退出登录、取消订单）。
/// 返回 true=确认 / false|null=取消。自动套品牌主题（走 xbShowDialog）。
Future<bool> xbConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool destructive = false,
}) async {
  final ok = await xbShowDialog<bool>(
    context: context,
    brandColor: xbBrandColor(),
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: XbTokens.bad)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}
