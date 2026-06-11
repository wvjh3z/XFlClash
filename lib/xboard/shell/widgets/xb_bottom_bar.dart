/// 形态 A 自定义底栏（spec `xboard-form-a-ui-revamp` / W1.3 / R1.5）。
///
/// **不复用** FlClash `NavigationBar`（FlClash 导航与 PageLabel 状态机耦合）；自建以解耦。
/// Material Symbols 图标 + 选中态主题色（R1.5）；深浅色跟随 `Theme.of(context)`（R8.1）。
///
/// **适配层铁律**：纯 UI widget，不 import `lib/views/**` / FlClash internal provider。
library;

import 'package:flutter/material.dart';

import '../../widgets/xb_motion.dart';

/// 底栏单项数据。
class XbBottomBarItem {
  const XbBottomBarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// 形态 A 三项自定义底栏（首页 / 节点 / 我的）。
class XbBottomBar extends StatelessWidget {
  const XbBottomBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.items = defaultItems,
  });

  /// 当前选中 index。
  final int currentIndex;

  /// 点击切换回调（传入目标 index）。
  final ValueChanged<int> onTap;

  /// 底栏项（默认三项）。
  final List<XbBottomBarItem> items;

  /// 形态 A 默认三项（首页 / 节点 / 我的）。
  static const List<XbBottomBarItem> defaultItems = [
    XbBottomBarItem(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      label: '首页',
    ),
    XbBottomBarItem(
      icon: Icons.public_outlined,
      selectedIcon: Icons.public,
      label: '节点',
    ),
    XbBottomBarItem(
      icon: Icons.person_outline,
      selectedIcon: Icons.person,
      label: '我的',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _XbBottomBarSlot(
                    item: items[i],
                    selected: i == currentIndex,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _XbBottomBarSlot extends StatelessWidget {
  const _XbBottomBarSlot({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final XbBottomBarItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 选中态主题色，未选中态 onSurfaceVariant（R1.5 / R8.1）。
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkResponse(
      onTap: onTap,
      radius: 48,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 选中态图标底加品牌色药丸（原型 .nav .it.on .ic{background:brand 13%}）。
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 60,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.13)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            // 选中图标轻微放大回弹（未选中 0.9 → 选中 1.0，emphasized 带过冲 = pop）。
            child: AnimatedScale(
              scale: selected ? 1.0 : 0.9,
              duration: XbMotion.reduced(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              curve: XbMotion.emphasized,
              child: Icon(selected ? item.selectedIcon : item.icon,
                  color: color, size: 24),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
