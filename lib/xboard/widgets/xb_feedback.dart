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
///
/// [icon] 非空 → 顶部圆形柔色徽标 + 标题/正文居中（与原型 logoutConfirm/15b、更换套餐确认同款
/// 精美弹窗语言）；徽标色 = destructive 红 / 否则琥珀 warn。
/// 按钮为**等宽双填充**（原型 .dlgrow：取消=浅灰填充、确认=品牌/红填充）——避免纯 TextButton
/// 取消键挨着实心确认键时显得很弱、不像可点。
Future<bool> xbConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool destructive = false,
  IconData? icon,
}) async {
  final ok = await xbShowDialog<bool>(
    context: context,
    brandColor: xbBrandColor(),
    builder: (ctx) {
      final t = XbTokens.of(ctx);
      final badgeColor = destructive ? XbTokens.bad : XbTokens.warn;
      final hasIcon = icon != null;
      return AlertDialog(
        title: hasIcon
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: badgeColor.withValues(alpha: 0.14),
                    ),
                    child: Icon(icon, size: 26, color: badgeColor),
                  ),
                  const SizedBox(height: 14),
                  Text(title, textAlign: TextAlign.center),
                ],
              )
            : Text(title),
        content: Text(
          message,
          textAlign: hasIcon ? TextAlign.center : TextAlign.start,
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    style: FilledButton.styleFrom(
                      backgroundColor: t.sfc,
                      foregroundColor: t.on,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(XbTokens.rMd)),
                    ),
                    child: Text(cancelLabel),
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: destructive
                        ? FilledButton.styleFrom(
                            backgroundColor: XbTokens.bad,
                            shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(XbTokens.rMd)),
                          )
                        : FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(XbTokens.rMd)),
                          ),
                    child: Text(confirmLabel),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
