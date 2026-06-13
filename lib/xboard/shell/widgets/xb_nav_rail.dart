/// 形态 A 桌面左侧导航栏（spec `xboard-form-a-ui-revamp` 桌面适配 / C-分支）。
///
/// 与 [XbBottomBar] 共享同一份导航项数据（[XbBottomBar.defaultItems]）与
/// `currentIndex` / `onTap` 契约——底栏与侧栏是「同一导航的两种朝向」，数据/选中逻辑单一来源。
/// 宽屏(桌面)用本竖版侧栏，窄屏(移动)用底栏，二者由断点切换。
///
/// **适配层铁律**：纯 UI widget，不 import `lib/views/**` / FlClash internal provider。
library;

import 'package:flutter/material.dart';

import '../../widgets/xb_motion.dart';
import 'xb_bottom_bar.dart' show XbBottomBar, XbBottomBarItem;

/// 形态 A 竖向导航栏（首页 / 节点 / 我的）。仅渲染导航项本身；
/// 品牌头、账号简卡、版本信息等外壳装饰由外壳(shell)拼装。
class XbNavRail extends StatelessWidget {
  const XbNavRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.items = XbBottomBar.defaultItems,
  });

  /// 当前选中 index（与 [XbBottomBar] 同契约）。
  final int currentIndex;

  /// 点击切换回调（传入目标 index）。
  final ValueChanged<int> onTap;

  /// 导航项（默认复用底栏三项，单一数据源）。
  final List<XbBottomBarItem> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _XbNavRailSlot(
              item: items[i],
              selected: i == currentIndex,
              onTap: () => onTap(i),
            ),
          ),
      ],
    );
  }
}

class _XbNavRailSlot extends StatelessWidget {
  const _XbNavRailSlot({
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
    final color = selected ? scheme.primary : scheme.onSurface;
    final iconColor = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // 选中态左侧高亮条（原型 .navit.on::before）。
            if (selected)
              Positioned(
                left: 0,
                top: 11,
                bottom: 11,
                child: Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(4)),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                height: 46,
                child: Row(
                  children: [
                    AnimatedScale(
                      scale: selected ? 1.0 : 0.92,
                      duration: XbMotion.reduced(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 260),
                      curve: XbMotion.emphasized,
                      child: Icon(selected ? item.selectedIcon : item.icon,
                          color: iconColor, size: 22),
                    ),
                    const SizedBox(width: 13),
                    Text(
                      item.label,
                      style: TextStyle(
                        color: color,
                        fontSize: 14.5,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
