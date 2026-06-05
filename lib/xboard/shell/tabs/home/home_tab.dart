/// 形态 A 首页 Tab（spec `xboard-form-a-ui-revamp` / W3.6 / R2·R3·R5.4）。
///
/// 组装：游客 banner（R5.4）+ 连接球（W3.1）+ 速度卡（W3.2）+ 当前线路卡（W3.3）+
/// 代理模式段（W3.4）。进入时纠偏 direct 模式（adapter，design 风险②）。
///
/// **适配层铁律**：全部内核交互经 adapters；游客态读形态 B `authStateProvider`（◇）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';

import '../../adapters/xb_mode_adapter.dart';
import 'xb_connect_orb.dart';
import 'xb_line_card.dart';
import 'xb_mode_segment.dart';
import 'xb_speed_card.dart';

/// 首页 Tab。
class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key, this.onTapToNodes, this.onTapLogin});

  /// 点击线路卡 → 切节点 Tab（shell 注入）。
  final VoidCallback? onTapToNodes;

  /// 点击登录 banner → 弹登录 sheet（shell 注入，W5 接线）。
  final VoidCallback? onTapLogin;

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  @override
  void initState() {
    super.initState();
    // 进入首页纠偏 direct（formA 二选一无法表达，design 风险②）。下一帧执行（避免 build 期改 provider）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(xbModeAdapterProvider).normalizeDirectIfNeeded(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isGuest) ...[
              _GuestBanner(onTapLogin: widget.onTapLogin),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            const Center(child: XbConnectOrb()),
            const SizedBox(height: 20),
            const XbSpeedCard(),
            const SizedBox(height: 12),
            XbLineCard(onTapToNodes: widget.onTapToNodes),
            const SizedBox(height: 20),
            const XbModeSegment(),
          ],
        ),
      ),
    );
  }
}

/// 游客登录引导横幅（R5.4）。
class _GuestBanner extends StatelessWidget {
  const _GuestBanner({this.onTapLogin});

  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTapLogin,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.lock_open, size: 20, color: scheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '登录后开启加密保护',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}
