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
import 'xb_ui_kit.dart' show XbIconBadge;

/// 顶部同步横幅（原型 `.syncbar`）：琥珀柔底 + 旋转 spinner + 文案。
/// 用于"已登录但订阅/账号数据竞速未完成"的过渡态。
class XbSyncBanner extends StatelessWidget {
  const XbSyncBanner({super.key, this.text = '正在同步账号与套餐信息…'});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    const warn = XbTokens.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Color.alphaBlend(warn.withValues(alpha: 0.11), t.card),
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        border: Border.all(color: warn.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: warn),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: t.onWarn),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shimmer 占位条（原型 `.sk`）：左→右流光动画，用于骨架屏。
class XbSkeletonBar extends StatefulWidget {
  const XbSkeletonBar({
    super.key,
    this.widthFactor = 1,
    this.height = 13,
    this.radius = 8,
  });

  final double widthFactor;
  final double height;
  final double radius;

  @override
  State<XbSkeletonBar> createState() => _XbSkeletonBarState();
}

class _XbSkeletonBarState extends State<XbSkeletonBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widget.widthFactor.clamp(0.0, 1.0),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final dx = (_c.value * 2 - 1); // -1 → 1
          return Container(
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              gradient: LinearGradient(
                begin: Alignment(dx - 1, 0),
                end: Alignment(dx + 1, 0),
                colors: [t.sfc, t.hair, t.sfc],
                stops: const [0.25, 0.5, 0.75],
              ),
            ),
          );
        },
      ),
    );
  }

  double get widthFactor => widget.widthFactor;
}

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
                  fontSize: 15, fontWeight: FontWeight.w600, color: t.on)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// ═══════════════════════════════ 标题 / 标签 ═══════════════════════════════

/// 分组小标题（原型 .grp）：普通灰、13px、w600（去大写/字距，组间距加大）。
class XbGroupLabel extends StatelessWidget {
  const XbGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 7),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
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
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: t.on)),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// 标签徽章（原型 .tag / .gbtag / .ty）：小圆角彩底标签。
class XbTag extends StatelessWidget {
  const XbTag(this.text,
      {super.key, this.color, this.filled = false, this.elevated = false});

  final String text;

  /// 标签色（默认品牌色）。
  final Color? color;

  /// true = 实心彩底白字；false = 淡彩底彩字。
  final bool filled;

  /// true = 浮起态（实心 + 投影 + 字号微增）：用于浮在卡片角的「省 N%」折扣标签，
  /// 让小号白字从底色上清晰浮起、不被裁切（原型 `.pcell .tag.save` 精致化）。
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    final solid = filled || elevated;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: elevated ? 9 : 9, vertical: elevated ? 4 : 3),
      decoration: BoxDecoration(
        color: solid ? c : c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(elevated ? 9 : 8),
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: c.withValues(alpha: 0.45),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                  spreadRadius: -3,
                ),
              ]
            : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: elevated ? 11.5 : 11,
          height: 1,
          fontWeight: FontWeight.w600,
          color: solid ? Colors.white : c,
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
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: [
            XbIconBadge(
              icon: icon,
              size: 32,
              radius: 8,
              background: t.sfc,
              iconColor: danger ? scheme.error : t.on,
              iconSize: 17,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: TextStyle(fontSize: 14.5, color: fg)),
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
                  fontWeight: total ? FontWeight.w700 : FontWeight.w600,
                  color: valueColor ?? (total ? scheme.primary : t.on),
                  // 键值右值多为金额/数字 → 等宽（tabular）：竖排对齐、跳变不抖动（商用支付场景规范）。
                  fontFeatures: const [FontFeature.tabularFigures()])),
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
                        fontSize: 17, fontWeight: FontWeight.w700, color: color)),
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

/// 待支付订单横幅（原型 `.pendcard`）：黄色框 + 订单概要 + 「取消订单 / 立即支付」两按钮。
///
/// 用于"我的 / 续费 / 购买 / 流量重置"四处顶部（有 pending 订单时显示），风格参考流量重置卡
/// （warn 琥珀），但带两个操作。文案：「有待支付订单」+「套餐名 · 周期」+ 金额。
class XbPendingOrderBanner extends StatelessWidget {
  const XbPendingOrderBanner({
    super.key,
    required this.subtitle,
    required this.amountText,
    required this.onCancel,
    required this.onPay,
    this.cancelling = false,
  });

  /// 副标题（原型「标准套餐 · 季付」，不含订单号）。
  final String subtitle;

  /// 金额文案（如 `¥40.00`）。
  final String amountText;
  final VoidCallback? onCancel;
  final VoidCallback? onPay;

  /// 取消进行中（按钮 loading）。
  final bool cancelling;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    const warn = XbTokens.warn;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Color.alphaBlend(warn.withValues(alpha: 0.11), t.card),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: warn.withValues(alpha: 0.32)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // 琥珀圆角徽标包时钟图标（全 app 徽标语言统一）。
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: warn.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(XbTokens.rSm),
                ),
                child: const Icon(Icons.schedule, color: warn, size: 20),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('有待支付订单',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: t.on)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11, height: 1.45, color: t.onv)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(amountText,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: warn,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              // 取消订单（描边）。
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: cancelling ? null : onCancel,
                  icon: cancelling
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: warn))
                      : const Icon(Icons.close, size: 18),
                  label: const Text('取消订单'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.onv,
                    side: BorderSide(color: warn.withValues(alpha: 0.30), width: 1.5),
                    minimumSize: const Size.fromHeight(42),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // 立即支付（实心 warn 黄）。
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPay,
                  icon: const Icon(Icons.payment, size: 18),
                  label: const Text('立即支付'),
                  style: FilledButton.styleFrom(
                    backgroundColor: warn,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(42),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
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
          // 品牌圆角徽标包说明图标（全 app 徽标语言统一，不裸放）。
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(XbTokens.rSm),
            ),
            child: Icon(icon, size: 21, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(text,
                  style: TextStyle(fontSize: 13, height: 1.55, color: t.on)),
            ),
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
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String? description;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  /// 次要文字链接（原型空态的「刷新重试」），显示在主按钮下方。
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

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
            if (secondaryLabel != null) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: onSecondary,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(secondaryLabel!),
                style: TextButton.styleFrom(foregroundColor: scheme.primary),
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
                  top: -9,
                  right: 8,
                  child: XbTag(tag!, color: tagColor, elevated: true),
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

/// 加载失败重试块（多页通用）：图标 + 文案 + 重试按钮。
class XbErrorRetry extends StatelessWidget {
  const XbErrorRetry({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 40, color: t.onv),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════ 说明弹窗（共用） ═══════════════════════════════

/// 说明弹窗的单条解释项数据（原型 `.modeexp`：图标 + 标题 + 说明）。
class XbInfoItem {
  const XbInfoItem({required this.icon, required this.title, required this.desc});

  final IconData icon;
  final String title;
  final String desc;
}

/// 通用说明底部 sheet（原型 modeInfoSheet / groupTypeInfoSheet 统一抽象）。
///
/// **统一**：标题**居中**（原型 `.sheet h3{text-align:center}`）+ 居中副标题 + 一组 `.modeexp`
/// 解释卡（浅灰底 + 42 品牌淡底图标块）+ 品牌实心「知道了」。代理模式说明、线路分组类型说明
/// 都用它，改一处全改、风格一致（不再各写一份导致标题对齐/按钮样式飘）。
///
/// 用法：`showXbInfoSheet(context, title: '代理模式说明', subtitle: '两种模式按需切换', items: [...])`
class XbInfoSheet extends StatelessWidget {
  const XbInfoSheet({
    super.key,
    required this.title,
    required this.items,
    this.subtitle,
    this.confirmLabel = '知道了',
  });

  final String title;
  final String? subtitle;
  final List<XbInfoItem> items;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题居中（对齐原型 .sheet h3）。
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700, color: t.on),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: t.onv),
                ),
              ],
              const SizedBox(height: 16),
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 11),
                _XbInfoItemCard(item: items[i]),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(confirmLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 说明项卡（原型 `.modeexp`）：浅灰底 + 42×42 品牌淡底图标块 + 标题(w500) + 说明。
class _XbInfoItemCard extends StatelessWidget {
  const _XbInfoItemCard({required this.item});

  final XbInfoItem item;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: t.sfc,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          XbIconBadge(
            icon: item.icon,
            size: 42,
            radius: XbTokens.rMd,
            background: scheme.primary.withValues(alpha: 0.12),
            iconColor: scheme.primary,
            iconSize: 22,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500, color: t.on)),
                const SizedBox(height: 4),
                Text(item.desc,
                    style: TextStyle(fontSize: 12.5, height: 1.6, color: t.onv)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
