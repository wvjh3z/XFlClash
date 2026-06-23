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
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/widgets/xb_center_toast.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbIconBadge;
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';
import 'package:fl_clash/widgets/widgets.dart' show EmojiText;

import '../../adapters/xb_mode_adapter.dart';
import '../../adapters/xb_nodes_adapter.dart';
import '../../adapters/xb_network_adapter.dart';
import '../../adapters/xb_takeover_adapter.dart';
import '../../adapters/xb_traffic_adapter.dart';
import '../../widgets/xb_content_header.dart';
import '../../widgets/xb_responsive.dart';
import 'xb_connect_orb.dart';
import 'xb_expiry_card.dart';
import 'home_latency_provider.dart';
import 'xb_ip_card.dart';
import 'xb_line_card.dart';
import 'xb_mode_segment.dart';
import 'mode_info_sheet.dart';
import 'takeover_info_sheet.dart';
import 'xb_speed_card.dart';

/// 首页双栏布局：可用宽 ≥ [XbBreakpoints.desktop] 才双栏，否则单列（C-分支，策略见 xb_responsive）。

/// 首页 Tab。
class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key, this.onTapToNodes, this.onTapLogin, this.onTapRenew});

  /// 点击线路卡 → 切节点 Tab（shell 注入）。带上选中节点的所属分组 + 节点名供定位。
  final void Function(String? group, String? node)? onTapToNodes;

  /// 点击登录 banner → 弹登录 sheet（shell 注入，W5 接线）。
  final VoidCallback? onTapLogin;

  /// 点击到期卡「去续费」→ 跳「我的」Tab（shell 注入）。
  final VoidCallback? onTapRenew;

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

  @override
  Widget build(BuildContext context) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;
    final scheme = Theme.of(context).colorScheme;
    // 首页延迟：读独立的 homeLatencyProvider（仅「连接/切换节点」时由 measureCurrentNodeBest
    // 现测 3 次取最低写入），不读节点列表的全局延迟表。游客 → null（显示「--」）。
    final homeLatency = ref.watch(homeLatencyProvider);
    final latencyMs = isGuest ? null : homeLatency.ms;

    // C-分支：按「内容区自身可用宽度」决定单列/双栏（而非全局 isMobileView）——
    // 桌面内容区 = 窗口宽 − 左侧 NavRail，窄窗口（或窄桌面窗）自动退回单列，避免拥挤溢出。
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumn = xbIsDesktopWidth(constraints.maxWidth);
          return twoColumn
              ? _buildDesktopBody(
                  isGuest: isGuest,
                  latencyMs: latencyMs,
                  scheme: scheme,
                  availWidth: constraints.maxWidth)
              : _buildMobileBody(
                  isGuest: isGuest, latencyMs: latencyMs, scheme: scheme);
        },
      ),
    );
  }

  /// 移动端单列（原布局，保持不变）。
  Widget _buildMobileBody({
    required bool isGuest,
    required int? latencyMs,
    required ColorScheme scheme,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // AppBar 标题「MyClient」+ 右侧更新提示（有新版时）。
          const _HomeHeader(),
          if (isGuest) ...[
            _GuestBanner(onTapLogin: widget.onTapLogin),
            const SizedBox(height: 12),
          ],
          // 套餐到期提醒卡（已登录 + 剩≤7天/已过期才显示）。
          XbExpiryCard(onTapRenew: widget.onTapRenew),
          const SizedBox(height: 8),
          Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 品牌红光晕（原型 `.aura`）：球后径向辉光，未连接也显示（与桌面 hero 一致）。
                IgnorePointer(
                  child: Container(
                    width: 255,
                    height: 255,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          scheme.primary.withValues(alpha: 0.20),
                          scheme.primary.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.66],
                      ),
                    ),
                  ),
                ),
                XbConnectOrb(
                  showLock: isGuest,
                  guest: isGuest,
                  onBlocked: () => _checkConnectBlock(isGuest),
                ),
              ],
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
    );
  }

  /// 桌面双栏（C-分支，原型屏1）：内容居中限宽；上方页头 + 游客/到期卡通栏，下方
  /// 左栏 = 连接球 + 速率，右栏 = 当前线路 / 代理模式 / 出口信息。复用移动端同款子组件。
  Widget _buildDesktopBody({
    required bool isGuest,
    required int? latencyMs,
    required ColorScheme scheme,
    required double availWidth,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 固定标题栏（原型 .chd）：标题「首页」+ 右侧更新胶囊，底部分隔线。
        const XbContentHeader(
          title: '首页',
          trailing: _HomeUpdatePill(large: true),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
            child: Center(
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: xbContentMaxWidth(availWidth)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isGuest) ...[
                      _GuestBanner(
                          onTapLogin: widget.onTapLogin, centered: true),
                      const SizedBox(height: 12),
                    ],
                    XbExpiryCard(onTapRenew: widget.onTapRenew, centered: true),
                    const SizedBox(height: 8),
                    Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 左栏：连接球 hero 卡（重心）+ 三个独立速率磁贴。
                  Expanded(
                    flex: 56,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _HomeHeroCard(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Center(
                                child: XbConnectOrb(
                                  size: 196,
                                  showLock: isGuest,
                                  guest: isGuest,
                                  statusBelow: true,
                                  onBlocked: () => _checkConnectBlock(isGuest),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        _SpeedTilesDesktop(latencyMs: latencyMs),
                      ],
                    ),
                  ),
                  const SizedBox(width: 22),
                  // 右栏：当前线路（已登录）/ 代理模式 / 出口信息，各自成「带标题卡」。
                  Expanded(
                    flex: 44,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!isGuest) ...[
                          _DesktopInfoCard(
                            icon: Icons.lan_outlined,
                            title: '当前线路',
                            child: XbLineCard(
                              embedded: true,
                              onTapToNodes: widget.onTapToNodes,
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        _DesktopInfoCard(
                          icon: Icons.tune,
                          title: '代理模式',
                          onInfo: () => showModeInfoSheet(context),
                          child: const XbModeSegment(showTitle: false),
                        ),
                        const SizedBox(height: 14),
                        const _DesktopInfoCard(
                          icon: Icons.public,
                          title: '出口信息',
                          child: XbIpCard(embedded: true),
                        ),
                        const SizedBox(height: 14),
                        // 网络接管方式（桌面专属）：系统代理 / 虚拟网卡(TUN) 两个独立开关。
                        _DesktopInfoCard(
                          icon: Icons.settings_ethernet,
                          title: '网络接管方式',
                          onInfo: () => showTakeoverInfoSheet(context),
                          child: const _TakeoverOptions(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
        ),
      ),
      ],
    );
  }
}

/// 首页头部（移动端）：标题「MyClient」+ 右侧「有新版本」绿色胶囊（点击弹更新弹窗）。
class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'MyClient',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          // 有新版本时显示绿色胶囊提示。
          const _HomeUpdatePill(),
        ],
      ),
    );
  }
}

/// 「有新版本」绿色胶囊（点击弹更新弹窗）。无更新时不占位。
/// 桌面 [large]=true：字号 13 + 更大内距（PC 空间充裕，提示更醒目，原型 .update-pill）。
class _HomeUpdatePill extends StatelessWidget {
  const _HomeUpdatePill({this.large = false});

  final bool large;

  @override
  Widget build(BuildContext context) {
    return Consumer(builder: (ctx, r, _) {
      final update = r.watch(availableUpdateProvider);
      if (update == null) return const SizedBox.shrink();
      return GestureDetector(
        onTap: () => showXbUpdateDialog(ctx, update),
        child: Container(
          padding: large
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 7)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0x142E8B57),
            border: Border.all(color: const Color(0x382E8B57), width: 1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: EmojiText(
            '🎉 有新版本啦，巨大更新',
            style: TextStyle(
              fontSize: large ? 13 : 11,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF2E8B57),
            ),
          ),
        ),
      );
    });
  }
}

/// 游客登录引导横幅（R5.4）—— 原型红渐变卡 + 白图标 + 右侧实心「登录」按钮。
class _GuestBanner extends StatelessWidget {
  const _GuestBanner({this.onTapLogin, this.centered = false});

  final VoidCallback? onTapLogin;

  /// 桌面态（原型 `.gbanner{width:fit-content;margin:0 auto}`）：按内容宽度收窄并居中，
  /// 不撑满整个内容区（避免横幅过长）。移动端默认 false → 全宽（原型 `.loginbar` 全宽）。
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textCol = Column(
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
    );
    final banner = Material(
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
              // 桌面 fit-content → min（横幅按内容收窄）；移动全宽 → max。
              mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
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
                // 主副文案：全宽态 Expanded（把按钮顶到右缘）；居中态 Flexible（按内容收窄）。
                centered
                    ? Flexible(fit: FlexFit.loose, child: textCol)
                    : Expanded(child: textCol),
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
    // 桌面：居中收窄（Align 让子按自身首选宽度布局）。移动：返回全宽横幅。
    return centered ? Align(alignment: Alignment.center, child: banner) : banner;
  }
}

/// 桌面首页左栏连接球 hero 卡（原型 `.herocard`）：渐变面 + 细边 + 强阴影，连接球居中其中。
class _HomeHeroCard extends StatelessWidget {
  const _HomeHeroCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [t.sf2, t.card],
        ),
        borderRadius: BorderRadius.circular(XbTokens.rLg),
        border: Border.all(color: t.line),
        boxShadow: t.shadow2,
      ),
      child: Stack(
        children: [
          // 品牌红径向光晕（原型 `.herocard .glow`）：球后顶部居中淡红辉光，营造「泛红」科技感。
          Positioned(
            top: -26,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 380,
                height: 380,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      scheme.primary.withValues(alpha: 0.13),
                      scheme.primary.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.64],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 30, 24, 26),
            child: Center(child: child),
          ),
        ],
      ),
    );
  }
}

/// 桌面首页左栏速率磁贴组（原型 `.mtiles`）：下载 / 上传 / 延迟 三块独立大磁贴
/// （图标徽标在上、大号数值居中、标签在下）。复用 `xbTrafficAdapterProvider`（与移动速度卡同源）。
class _SpeedTilesDesktop extends ConsumerWidget {
  const _SpeedTilesDesktop({this.latencyMs});

  final int? latencyMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final adapter = ref.watch(xbTrafficAdapterProvider);
    final traffic = adapter.currentTraffic(ref);
    final down = _fmt(traffic.down);
    final up = _fmt(traffic.up);
    final hasLatency = latencyMs != null;
    return Row(
      children: [
        Expanded(
          child: _SpeedTile(
            icon: Icons.south,
            iconColor: scheme.primary,
            value: down.value,
            unit: down.unit,
            label: '下载',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SpeedTile(
            icon: Icons.north,
            iconColor: XbTokens.ok,
            value: up.value,
            unit: up.unit,
            label: '上传',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SpeedTile(
            icon: Icons.network_ping,
            iconColor: scheme.onSurfaceVariant,
            value: hasLatency ? latencyMs.toString() : '--',
            unit: hasLatency ? 'ms' : '',
            label: '延迟',
          ),
        ),
      ],
    );
  }

  static ({String value, String unit}) _fmt(num bytesPerSec) {
    final kbps = bytesPerSec * 8 / 1000;
    if (kbps <= 0) return (value: '0', unit: 'Kbps');
    if (kbps < 1000) return (value: kbps.round().toString(), unit: 'Kbps');
    final mbps = kbps / 1000;
    return (
      value: mbps >= 100 ? mbps.round().toString() : mbps.toStringAsFixed(1),
      unit: 'Mbps',
    );
  }
}

/// 单个速率磁贴（图标徽标 + 大号数值 + 标签）。
class _SpeedTile extends StatelessWidget {
  const _SpeedTile({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.unit,
    required this.label,
  });

  final IconData icon;
  final Color iconColor;
  final String value;
  final String unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(XbTokens.rLg),
        border: Border.all(color: t.line),
        boxShadow: t.shadow1,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.sfc,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 19, color: iconColor),
          ),
          const SizedBox(height: 9),
          RichText(
            text: TextSpan(
              text: value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              children: unit.isEmpty
                  ? null
                  : [
                      TextSpan(
                        text: ' $unit',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面右栏「带标题信息卡」（原型 `.icard` + `.ttl`）：标题行（图标 + 标签）+ 内容。
class _DesktopInfoCard extends StatelessWidget {
  const _DesktopInfoCard({
    required this.icon,
    required this.title,
    required this.child,
    this.onInfo,
  });

  final IconData icon;
  final String title;
  final Widget child;

  /// 非空 → 标题右侧显示 ⓘ 说明按钮（如代理模式说明，参考移动端）。
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(XbTokens.rLg),
        border: Border.all(color: t.line),
        boxShadow: t.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: t.onv),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: t.onv,
                  letterSpacing: 0.3,
                ),
              ),
              if (onInfo != null)
                InkWell(
                  onTap: onInfo,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(Icons.help_outline, size: 15, color: t.onv),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// 网络接管方式选项（桌面专属）：系统代理 / 虚拟网卡(TUN) 两个独立开关，
/// 经 [xbTakeoverAdapterProvider] 收口读写（适配层铁律）。两者互不互斥、可同时开。
class _TakeoverOptions extends ConsumerWidget {
  const _TakeoverOptions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapter = ref.watch(xbTakeoverAdapterProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TakeoverRow(
          icon: Icons.shuffle,
          label: '系统代理',
          value: adapter.systemProxyEnabled(ref),
          onChanged: (v) => adapter.setSystemProxy(ref, v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Divider(height: 1, color: XbTokens.of(context).hair),
        ),
        _TakeoverRow(
          icon: Icons.lan_outlined,
          label: '虚拟网卡 (TUN)',
          value: adapter.tunEnabled(ref),
          onChanged: (v) => adapter.setTun(ref, v),
        ),
      ],
    );
  }
}

/// 单个接管开关行：方形图标徽标 + 名称 + Switch（原型 .tkrow）。
class _TakeoverRow extends StatelessWidget {
  const _TakeoverRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          XbIconBadge(
            icon: icon,
            size: 36,
            radius: XbTokens.rMd,
            background: t.sfc,
            iconColor: t.onv,
            iconSize: 19,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: t.on,
              ),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}
