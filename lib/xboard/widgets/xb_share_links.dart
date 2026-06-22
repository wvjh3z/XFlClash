/// 分享地址卡（form-a · 邀请返佣页 + 分享好友页共用组件）。
///
/// **设计意图**：「主要地址 / 备用地址 + 复制」这套行在邀请返佣页与分享好友页重复出现，抽成单一
/// 组件（框架思维，改一处全改）。**故意不展示具体 URL**（用户决策：只给标签 + 复制，避免长串
/// 网址干扰 / 误读）。点复制 → 写剪贴板 + [xbToast] 反馈。
///
/// model-agnostic：只吃 URL 字符串，不依赖域模型（保持 `widgets/` 层与 `models/` 解耦）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'xb_components.dart' show XbCard;
import 'xb_feedback.dart' show xbToast;
import 'xb_theme.dart' show XbTokens;

/// 分享地址卡：主要地址 + 可选备用地址（行间细分隔线）。[backupUrl] 为空则只显示主要地址。
///
/// [inviteCode] 非空时（邀请返佣页）→ 点复制不再只复制裸地址，而是复制一段「下载地址 + 浏览器
/// 打开提示 + 我的邀请码」的分享文案（见 [buildShareText]）；为空时（分享好友页·免登录无邀请码）
/// → 保持复制裸地址的原行为。
class XbShareLinksCard extends StatelessWidget {
  const XbShareLinksCard({
    super.key,
    required this.primaryUrl,
    this.backupUrl = '',
    this.inviteCode,
  });

  final String primaryUrl;
  final String backupUrl;

  /// 邀请码（可空）。非空 → 复制时附带邀请码与提示文案。
  final String? inviteCode;

  @override
  Widget build(BuildContext context) {
    final hasBackup = backupUrl.isNotEmpty;
    // 桌面宽窗下限定卡片宽度：行内复制按钮贴右边缘（保持原型布局），但整行宽度收到手机级，
    // 避免行宽 700+px 时标签与复制按钮之间被拉出几百像素空隙（即「地址行显示很长」）。
    // 手机屏本就窄于此值，ConstrainedBox 不生效，无影响。
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: XbCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              _ShareLinkRow(
                  label: '主要地址', url: primaryUrl, inviteCode: inviteCode),
              if (hasBackup) ...[
                Divider(
                    height: 1, thickness: 1, color: XbTokens.of(context).hair),
                _ShareLinkRow(
                    label: '备用地址', url: backupUrl, inviteCode: inviteCode),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 组合分享文案：下载地址 + 浏览器打开提示 +（仅邀请页）我的邀请码。
///
/// 文案面向「发给好友」：提示对方别在微信/QQ 内置浏览器里打开（常被拦截/无法下载）。
/// [code] 非空（邀请返佣页）→ 末尾附「注册填我的邀请码」；为空（分享好友页·无邀请码）→ 省略该行，
/// 仍保留地址与浏览器提示。
String buildShareText(String url, String? code) {
  final text = '下载地址：$url\n'
      '温馨提示：请勿在微信 / QQ 等 App 内直接打开，请复制链接到浏览器中打开下载。';
  if (code == null || code.isEmpty) return text;
  return '$text\n注册时填写我的邀请码：$code';
}

/// 单条分享地址行（不展示具体 URL，只「图标 + 标签 + 复制按钮」）。
class _ShareLinkRow extends StatelessWidget {
  const _ShareLinkRow({required this.label, required this.url, this.inviteCode});
  final String label;
  final String url;
  final String? inviteCode;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.sfc,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.link, size: 18, color: t.onv),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: t.on)),
          ),
          const SizedBox(width: 8),
          Material(
            color: Color.alphaBlend(brand.withValues(alpha: 0.09), t.card),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                final hasCode = inviteCode != null && inviteCode!.isNotEmpty;
                Clipboard.setData(
                    ClipboardData(text: buildShareText(url, inviteCode)));
                xbToast(context, hasCode ? '已复制下载链接与邀请码' : '已复制$label');
              },
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(Icons.content_copy, size: 18, color: brand),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
