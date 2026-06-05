/// 形态 A 组合组件库（spec `xboard-form-a-ui-revamp` / 原型 full.html 复用模式）。
///
/// **设计意图**：原型风格高度统一 —— 卡片 / 分组标签 / 返回栏 / 列表行 / 键值行 / 状态卡 /
/// 空态块 / 底部操作栏 / 套餐选项 等组合模式在多屏反复出现。本库把它们抽成**可复用 widget**
/// （全部从 [XbTokens] 读 token，零硬编码魔法数字），各页面直接调用 → 统一风格、改一处全改。
///
/// 配合 [buildXbTheme]（原子级：按钮/输入框/卡片主题）形成完整设计框架：
///   - 原子（按钮/输入框/卡片底）→ ThemeData 子主题（吃默认值）
///   - 组合（区块卡/列表行/键值行/空态…）→ 本库 widget
library;

import 'package:flutter/material.dart';

import 'xb_theme.dart';

// ═══════════════════════════════ 容器 ═══════════════════════════════

/// 通用卡片（原型 .card / .dcard）：白底 + 圆角 + 细边 + sd1 阴影。
class XbCard extends StatelessWidget {
  const XbCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.radius = XbTokens.rCard,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final shape = BoxDecoration(
      color: t.card,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: t.line),
      boxShadow: t.shadow1,
    );
    if (onTap == null) {
      return Container(decoration: shape, padding: padding, child: child);
    }
    return Material(
      color: t.card,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: Ink(
          decoration: shape,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 带标题的区块卡（原型 .dcard + .dt）：标题 + 内容。
class XbSectionCard extends StatelessWidget {
  const XbSectionCard({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return XbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: t.on)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// ═══════════════════════════════ 标题 / 标签 ═══════════════════════════════

/// 分组小标题（原型 .grp）：全大写、字距、灰、小字。
class XbGroupLabel extends StatelessWidget {
  const XbGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 9),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
          color: t.onv,
        ),
      ),
    );
  }
}

/// 大标题 AppBar 文案（原型 .abar .t）—— 用于 Tab 顶部（非二级页，二级页用 AppBar）。
class XbScreenTitle extends StatelessWidget {
  const XbScreenTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: t.on)),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// 标签徽章（原型 .tag / .gbtag / .ty）：小圆角彩底标签。
class XbTag extends StatelessWidget {
  const XbTag(this.text, {super.key, this.color, this.filled = false});

  final String text;

  /// 标签色（默认品牌色）。
  final Color? color;

  /// true = 实心彩底白字；false = 淡彩底彩字。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? c : c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: filled ? Colors.white : c,
        ),
      ),
    );
  }
}

// ═══════════════════════════════ 行 ═══════════════════════════════

/// 列表行（原型 .li）：图标方块 + 标签 + 可选副标题 + 尾部（角标/箭头）。
class XbListRow extends StatelessWidget {
  const XbListRow({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    this.trailing,
    this.badge,
    this.onTap,
    this.danger = false,
    this.showChevron = true,
  });

  final IconData icon;
  final String label;
  final String? subtitle;

  /// 尾部自定义 widget（优先于 badge/chevron）。
  final Widget? trailing;

  /// 尾部小字角标（如版本号 / "登录后可见"）。
  final String? badge;
  final VoidCallback? onTap;
  final bool danger;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fg = danger ? scheme.error : t.on;

    Widget? tail = trailing;
    tail ??= badge != null
        ? Text(badge!,
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600, color: t.onv))
        : (showChevron
            ? Icon(Icons.chevron_right, color: t.onv, size: 20)
            : null);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.sfc,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: danger ? scheme.error : t.on),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: TextStyle(fontSize: 15, color: fg)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        style: TextStyle(fontSize: 11.5, color: t.onv)),
                  ],
                ],
              ),
            ),
            if (tail != null) ...[const SizedBox(width: 8), tail],
          ],
        ),
      ),
    );
  }
}

/// 把多个 [XbListRow] 用细分隔线串成一张卡（原型 .card 内多 .li）。
class XbListCard extends StatelessWidget {
  const XbListCard({super.key, required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) {
        children.add(Divider(height: 1, thickness: 1, color: t.hair));
      }
    }
    return XbCard(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// 键值行（原型 .srow / .irow）：左标签 + 右值；total 变体加粗 + 品牌色大字。
class XbKeyValueRow extends StatelessWidget {
  const XbKeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.total = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool total;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: total ? 15 : 14,
                    fontWeight: total ? FontWeight.w700 : FontWeight.w400,
                    color: total ? t.on : t.onv)),
          ),
          const SizedBox(width: 8),
          Text(value,
              style: TextStyle(
                  fontSize: total ? 21 : 14,
                  fontWeight: total ? FontWeight.w800 : FontWeight.w600,
                  color: valueColor ?? (total ? scheme.primary : t.on))),
        ],
      ),
    );
  }
}

/// 细分隔线（原型 .sdiv）。
class XbHairline extends StatelessWidget {
  const XbHairline({super.key, this.margin = 8});
  final double margin;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Container(
        height: 1, margin: EdgeInsets.symmetric(vertical: margin), color: t.hair);
  }
}

// ═══════════════════════════════ 块 ═══════════════════════════════

/// 状态卡（原型 .statcard）：大图标 + 标题 + 副标题，按状态色调和柔底。
class XbStatusCard extends StatelessWidget {
  const XbStatusCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.10), t.card),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 34, color: color),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800, color: color)),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: TextStyle(fontSize: 12.5, color: t.onv)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 信息提示卡（原型 .infocard）：图标 + 多行说明，淡品牌底。
class XbInfoCard extends StatelessWidget {
  const XbInfoCard({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.08), t.card),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, height: 1.55, color: t.on)),
          ),
        ],
      ),
    );
  }
}

/// 居中空态/引导块（原型 .guestcta）：图标方块 + 标题 + 说明 + 主按钮。
class XbEmptyState extends StatelessWidget {
  const XbEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? description;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.sfc,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Icon(icon, size: 36, color: scheme.primary),
            ),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: t.on)),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(description!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.onv, height: 1.6)),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 18),
              actionIcon != null
                  ? FilledButton.icon(
                      onPressed: onAction,
                      icon: Icon(actionIcon, size: 18),
                      label: Text(actionLabel!),
                      style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 30, vertical: 14)),
                    )
                  : FilledButton(
                      onPressed: onAction,
                      style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 38, vertical: 14)),
                      child: Text(actionLabel!),
                    ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 套餐/周期选项卡（原型 .planopt / .pcell）：选中态品牌边 + 淡品牌底 + 可选角标。
class XbSelectableOption extends StatelessWidget {
  const XbSelectableOption({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.tag,
    this.tagColor,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final String? tag;
  final Color? tagColor;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final option = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: selected
            ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.07), t.card)
            : t.card,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: selected ? scheme.primary : t.line,
          width: 1.6,
        ),
      ),
      child: child,
    );
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: tag == null
          ? option
          : Stack(
              clipBehavior: Clip.none,
              children: [
                option,
                Positioned(
                  top: -8,
                  right: 15,
                  child: XbTag(tag!, color: tagColor, filled: true),
                ),
              ],
            ),
    );
  }
}

// ═══════════════════════════════ 导航 / 操作 ═══════════════════════════════

/// 二级页底部操作栏（原型 .dbar）：左次按钮（返回）+ 右主按钮（提交）。
class XbBottomActionBar extends StatelessWidget {
  const XbBottomActionBar({
    super.key,
    required this.primaryLabel,
    required this.onPrimary,
    this.primaryIcon,
    this.primaryLoading = false,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String primaryLabel;
  final VoidCallback? onPrimary;
  final IconData? primaryIcon;
  final bool primaryLoading;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            if (secondaryLabel != null) ...[
              OutlinedButton(
                onPressed: onSecondary ?? () => Navigator.of(context).pop(),
                child: Text(secondaryLabel!),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: FilledButton.icon(
                onPressed: primaryLoading ? null : onPrimary,
                icon: primaryLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.2, color: Colors.white))
                    : (primaryIcon != null
                        ? Icon(primaryIcon, size: 20)
                        : const SizedBox.shrink()),
                label: Text(primaryLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
