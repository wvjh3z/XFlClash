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
          SegmentedButton<XbMode>(
            segments: const [
              ButtonSegment(
                value: XbMode.smart,
                label: Text('智能'),
                icon: Icon(Icons.bolt),
              ),
              ButtonSegment(
                value: XbMode.global,
                label: Text('全局'),
                icon: Icon(Icons.public),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (sel) {
              if (sel.isNotEmpty) adapter.setMode(ref, sel.first);
            },
            showSelectedIcon: false,
          ),
        ],
      ),
    );
  }
}
