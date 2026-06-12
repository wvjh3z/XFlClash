/// 形态 A 首页 Tab（spec `xboard-form-a-ui-revamp` / W3.6 / R2·R3·R5.4）。
///
/// 组装：游客 banner（R5.4）+ 连接球（W3.1）+ 速度卡（W3.2）+ 当前线路卡（W3.3）+
/// 代理模式段（W3.4）。进入时纠偏 direct 模式（adapter，design 风险②）。
///
/// **适配层铁律**：全部内核交互经 adapters；游客态读形态 B `authStateProvider`（◇）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show AppUpdateModel;

import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/widgets/xb_center_toast.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbIconBadge;
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';

import '../../adapters/xb_mode_adapter.dart';
import '../../adapters/xb_nodes_adapter.dart';
import '../../adapters/xb_network_adapter.dart';
import 'xb_connect_orb.dart';
import 'home_latency_provider.dart';
import 'xb_ip_card.dart';
import 'xb_line_card.dart';
import 'xb_mode_segment.dart';
import 'xb_speed_card.dart';

/// 首页 Tab。
class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key, this.onTapToNodes, this.onTapLogin});

  /// 点击线路卡 → 切节点 Tab（shell 注入）。带上选中节点的所属分组 + 节点名供定位。
  final void Function(String? group, String? node)? onTapToNodes;

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
      // 进入首页触发一次出口 IP 检测（复用 FlClash 多源竞速；debounce 去重安全）。
      ref.read(xbNetworkAdapterProvider).startCheck(ref);
    });
  }

  /// 连接拦截 gate（首页连接球点击「连接」前判定）：
  /// - 游客 → notLoggedIn；
  /// - 已登录但无可用线路：订阅正在 sync → preparing；否则 → noNodes。
  /// 命中则弹居中提示并返回原因（不连接）；放行返回 null。
  XbConnectBlock? _checkConnectBlock(bool isGuest) {
    if (isGuest) {
      XbCenterToast.show(context, '请先登录账号后再连接',
          icon: Icons.info_outline_rounded);
      return XbConnectBlock.notLoggedIn;
    }
    final hasNodes = !ref.read(xbNodesAdapterProvider).nodesView(ref).isEmpty;
    if (hasNodes) return null; // 有线路 → 放行连接。
    // 无线路：区分「正在准备」与「确实无可用」。
    bool syncing = false;
    try {
      syncing = ref.read(subscriptionServiceProvider).isSyncing;
    } catch (_) {
      // provider 未就绪 → 当作非加载中。
    }
    if (syncing) {
      XbCenterToast.show(context, '正在准备线路，请稍候…',
          icon: Icons.hourglass_top_rounded);
      return XbConnectBlock.preparing;
    }
    XbCenterToast.show(context, '当前无可用线路，请前往「节点」刷新或购买套餐',
        icon: Icons.warning_amber_rounded);
    return XbConnectBlock.noNodes;
  }

  /// 弹出更新弹窗。
  void _showUpdateDialog(BuildContext ctx, AppUpdateModel info) {
    showXbUpdateDialog(ctx, info);
  }

  @override
  Widget build(BuildContext context) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;
    final scheme = Theme.of(context).colorScheme;
    // 首页延迟：读独立的 homeLatencyProvider（仅「连接/切换节点」时由 measureCurrentNodeBest
    // 现测 3 次取最低写入），不读节点列表的全局延迟表。游客 → null（显示「--」）。
    final homeLatency = ref.watch(homeLatencyProvider);
    final latencyMs = isGuest ? null : homeLatency.ms;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // AppBar 标题「MyClient」+ 右侧更新提示（有新版时）。
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'MyClient',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  // 有新版本时显示绿色胶囊提示
                  Consumer(builder: (ctx, r, _) {
                    final update = r.watch(availableUpdateProvider);
                    if (update == null) return const SizedBox.shrink();
                    return GestureDetector(
                      onTap: () => _showUpdateDialog(ctx, update),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0x1E2E8B57),
                          border: Border.all(
                              color: const Color(0x382E8B57), width: 1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          '🎉 有新版本啦',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2E8B57),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            if (isGuest) ...[
              _GuestBanner(onTapLogin: widget.onTapLogin),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            Center(
              child: XbConnectOrb(
                showLock: isGuest,
                guest: isGuest,
                onBlocked: () => _checkConnectBlock(isGuest),
              ),
            ),
            // 游客态说明行（原型 subline）。
            if (isGuest) ...[
              const SizedBox(height: 15),
              Text(
                '登录后开启加密保护',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                  height: 1.55,
                ),
              ),
            ],
            const SizedBox(height: 17),
            XbSpeedCard(latencyMs: latencyMs),
            // 当前线路卡：仅已登录显示（原型 guest 态无线路卡）。
            if (!isGuest) ...[
              const SizedBox(height: 12),
              XbLineCard(onTapToNodes: widget.onTapToNodes),
            ],
            const SizedBox(height: 20),
            const XbModeSegment(),
            // 出口 IP 卡（原型 .ipcard，代理模式段下方）。所有态显示（与登录无关）。
            const XbIpCard(),
          ],
        ),
      ),
    );
  }
}

/// 游客登录引导横幅（R5.4）—— 原型红渐变卡 + 白图标 + 右侧实心「登录」按钮。
class _GuestBanner extends StatelessWidget {
  const _GuestBanner({this.onTapLogin});

  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(XbTokens.rMd),
      child: InkWell(
        onTap: onTapLogin,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(XbTokens.rMd),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.10),
                  scheme.surfaceContainerLow,
                ),
                scheme.surfaceContainerLow,
              ],
            ),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.24),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            child: Row(
              children: [
                // 白图标 + 品牌红渐变方块。
                XbIconBadge(
                  icon: Icons.person,
                  size: 40,
                  radius: XbTokens.rMd,
                  iconColor: Colors.white,
                  iconSize: 20,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.18),
                        scheme.primary,
                      ),
                      scheme.primary,
                    ],
                  ),
                ),
                const SizedBox(width: 13),
                // 主副文案。
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '登录解锁全部功能',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '未登录 · 登录后即可连接',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // 右侧实心品牌红「登录」按钮。
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 17, vertical: 9),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(XbTokens.rSm),
                  ),
                  child: Text(
                    '登录',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
