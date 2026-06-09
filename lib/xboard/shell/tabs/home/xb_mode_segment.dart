/// 形态 A 代理模式切换段（spec `xboard-form-a-ui-revamp` / W3.4 / R3.1·R3.2·R3.6）。
///
/// 二选一控件「智能 / 全局」（仅 smart/global，隐藏 direct，R3.1）；标题右 ⓘ → 模式说明 sheet。
/// 切换 → `XbModeAdapter.setMode`（R3.2）。游客态 dim（R3.6）。
///
/// **适配层铁律**：经 `XbModeAdapter`（W2.3）读写，不直接碰 FlClash provider。
/// 游客态读形态 B `authStateProvider`（◇ 复用形态 B，自有 provider 非 FlClash 内部，无风险②）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';

import '../../adapters/xb_mode_adapter.dart';
import 'mode_info_sheet.dart';

/// 代理模式切换段。
class XbModeSegment extends ConsumerWidget {
  const XbModeSegment({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapter = ref.watch(xbModeAdapterProvider);
    final mode = adapter.currentMode(ref);
    final scheme = Theme.of(context).colorScheme;

    // 游客态 dim（R3.6）：未登录时控件半透明（仍可点，仅视觉弱化，与原型一致）。
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;

    return Opacity(
      opacity: isGuest ? 0.5 : 1.0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '代理模式',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 4),
              // ⓘ 模式说明（R3.3）。
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: Icon(Icons.help_outline, color: scheme.onSurfaceVariant),
                onPressed: () => showModeInfoSheet(context),
                tooltip: '代理模式说明',
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 自定义胶囊段（原型 .modeseg）：圆角槽 + 选中态主题色高亮卡，替代原生 SegmentedButton。
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                _ModePill(
                  icon: Icons.bolt,
                  label: '智能',
                  selected: mode == XbMode.smart,
                  onTap: () => adapter.setMode(ref, XbMode.smart),
                ),
                const SizedBox(width: 5),
                _ModePill(
                  icon: Icons.public,
                  label: '全局',
                  selected: mode == XbMode.global,
                  onTap: () => adapter.setMode(ref, XbMode.global),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 代理模式胶囊单项（原型 .modeseg .s / .s.on）。
class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected ? scheme.surfaceContainerLowest : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            // 选中：白卡底 + 品牌色描边（60%）+ 浮起阴影（不用品牌实心填充，避免整钮变红）。
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.60)
                  : Colors.transparent,
              width: 1.4,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
