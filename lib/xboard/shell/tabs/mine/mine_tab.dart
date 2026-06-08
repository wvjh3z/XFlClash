/// 形态 A 我的 Tab（spec `xboard-form-a-ui-revamp` / W4.3·W4.4·W4.5 / R6.1-R6.11）。
///
/// 组装：账号卡（W4.3，复用形态 B `userProfileProvider`，F14 先 gate authState）+ 续费/购买
/// 分流（W4.4，R6.4-R6.6）+ 流量重置入口（用量 ≥90% 才显示，R6.3）+ 设置入口（W4.5，经
/// `XbNativePageAdapter` push 原生 ToolsView，R6.8）+ 退出登录（◇ 复用形态 B logout 编排，R6.11）。
///
/// **复用边界**：账户/套餐/订单/支付/登出全链路 = ◇ **复用形态 B `lib/xboard/`**（自有代码，
/// 不经 adapter，无风险②）；仅设置入口（原生 ToolsView）= ◆ 经 `XbNativePageAdapter`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/pages/plan_list_page.dart';
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/app_version.dart';
import 'package:fl_clash/xboard/util/format.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_feedback.dart' show xbConfirm, xbBrandColor;
import 'package:fl_clash/xboard/widgets/xb_theme.dart'
    show xbPush, xbShowDialog, XbTokens;

import 'xb_settings_page.dart';

/// 用量达此比例才显示「流量重置」入口（R6.3）。
const _resetThreshold = 0.90;

/// 我的 Tab。
class MineTab extends ConsumerWidget {
  const MineTab({super.key, this.onTapLogin});

  /// 游客点击登录（shell 注入，W5 接线）。
  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text('我的', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          if (isGuest)
            _GuestCard(onTapLogin: onTapLogin)
          else
            const _AccountSection(),
          const SizedBox(height: 16),
          _SettingsSection(isGuest: isGuest),
        ],
      ),
    );
  }
}

/// 已登录账号区：账号卡（loading 骨架 / data）+ 续费购买分流 + 重置入口。
class _AccountSection extends ConsumerStatefulWidget {
  const _AccountSection();

  @override
  ConsumerState<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends ConsumerState<_AccountSection> {
  /// 重试中（点失败卡「重新加载」后到本次重拉落定前）：显示黄色「正在刷新服务」横幅。
  ///
  /// **不靠 `await provider.future` 撤横幅**——keepAlive FutureProvider 在 body 抛错且
  /// 当前无 widget watch 时 `.future` 不会完成（横幅永久卡住，已实测）。改为与套餐/订单页
  /// 一致：直接 await 反腐层 `getSubscription()`（返 XbResult 永不抛，必落定），完成后
  /// invalidate provider 刷新卡片 + 撤横幅。彻底绕开 `.future` 坑。
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    // 直接调反腐层（永不抛；含反腐层 failOver 切域名 + 5s 超时），无论成功失败都会落定。
    await ref.read(xboardServiceProvider).getSubscription();
    if (!mounted) return;
    // 用最新结果刷新账号卡 provider（成功 → 渲染卡片；失败 → 失败卡）+ 撤横幅。
    ref.invalidate(userProfileProvider);
    setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    // 重试中：与首次加载（booting）同布局——顶部刷新横幅 + 骨架卡 + 禁用按钮（卡片不丢，
    // 不突兀，原型 11d）。仅横幅文案不同（「正在刷新服务」vs「正在同步账号与套餐信息」）。
    if (_retrying) {
      return const _AccountSkeleton(bannerText: '正在刷新服务，请稍候…');
    }
    // F14：已 gate authenticated（MineTab 已判 isGuest），可安全 watch。
    final async = ref.watch(userProfileProvider);
    return async.when(
      loading: () => const _AccountSkeleton(),
      error: (e, _) => _AccountErrorCard(onRetry: _retry),
      data: (sub) => Column(
        children: [
          _AccountCard(sub: sub),
          const SizedBox(height: 12),
          _PlanActions(sub: sub),
        ],
      ),
    );
  }
}

/// 账号卡（原型 .plan：品牌渐变卡 + 白字 + 大号流量数字 + 到期/重置两行，R6.1/R6.2）。
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.sub});

  final XbDomainSubscription sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usedPct = sub.totalBytes == 0
        ? 0.0
        : (sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0);
    final pctInt = (usedPct * 100).round();
    final hot = usedPct >= _resetThreshold;
    const white = Colors.white;
    final white70 = Colors.white.withValues(alpha: 0.88);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XbTokens.rLg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(Colors.white.withValues(alpha: 0.18), scheme.primary),
            scheme.primary,
            Color.alphaBlend(Colors.black.withValues(alpha: 0.22), scheme.primary),
          ],
          stops: const [0, 0.55, 1],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.45),
            blurRadius: 40,
            offset: const Offset(0, 20),
            spreadRadius: -16,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶行：套餐名（左，主）+ 邮箱(掩码，右，次)。去头像（紧凑版）。
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  sub.planName ?? '未订阅套餐',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              // 邮箱占套餐名之外的剩余空间（Expanded），只有真超长才省略（方案1）。
              Expanded(
                child: Text(
                  sub.email,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: white70),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          // 流量行：大数字 + 单位 + 「已用 N%」(右)。
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _gb(sub.usedBytes),
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  color: white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '/ ${_gb(sub.totalBytes)} GB',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: white70,
                ),
              ),
              const Spacer(),
              Text(
                '已用 $pctInt%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: hot ? const Color(0xFFFFE1DA) : white70,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          // 进度条（白色填充）。
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: usedPct,
              minHeight: 10,
              backgroundColor: Colors.white.withValues(alpha: 0.25),
              valueColor: AlwaysStoppedAnimation(
                hot ? const Color(0xFFFFD9D2) : Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 11),
          // 到期行（保持原风格）。
          _InfoRow(icon: Icons.event, text: _expireText(sub), color: white70),
          // 流量重置行（有重置日才显示，保持原风格）。
          if (_resetText(sub) != null) ...[
            const SizedBox(height: 3),
            _InfoRow(
                icon: Icons.autorenew, text: _resetText(sub)!, color: white70),
          ],
        ],
      ),
    );
  }

  static String _gb(int bytes) => xbGb(bytes);

  static String _expireText(XbDomainSubscription sub) {
    if (sub.expiredAt == null) return '长期有效';
    final d = sub.expiredAt!;
    final ymd = xbDateMinute(d);
    // 剩余天数（原型：到期 YYYY-MM-DD HH:mm（剩 N 天））。
    final days = d
        .difference(DateTime(
            DateTime.now().year, DateTime.now().month, DateTime.now().day))
        .inDays;
    if (days < 0) return '已到期 $ymd';
    return '到期 $ymd（剩 $days 天）';
  }

  /// 流量重置行：有重置日才显示（一次性套餐无）。
  static String? _resetText(XbDomainSubscription sub) {
    final d = sub.nextResetAt;
    if (d != null) {
      final base = '流量重置 ${xbDateMinute(d)}';
      return sub.resetDay != null ? '$base（每月 ${sub.resetDay} 日）' : base;
    }
    if (sub.resetDay != null) return '流量重置 每月 ${sub.resetDay} 日';
    return null;
  }
}

/// 账号卡内信息行（图标 + 文案，白字半透明）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    );
  }
}

/// 续费/购买分流（R6.4/R6.5/R6.6）+ 流量重置入口（≥90%，R6.3）。
class _PlanActions extends ConsumerWidget {
  const _PlanActions({required this.sub});

  final XbDomainSubscription sub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usedPct = sub.totalBytes == 0
        ? 0.0
        : (sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0);
    final pctInt = (usedPct * 100).round();
    final showReset = usedPct >= _resetThreshold && sub.planId != null;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        SizedBox(
          height: 52,
          child: Row(
            children: [
              // 续费当前套餐（R6.4）：有套餐才显示，实心品牌按钮。
              if (!sub.hasNoPlan)
                Expanded(
                  child: FilledButton(
                    onPressed: () => _openRenew(context),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(XbTokens.rButton)),
                    ),
                    child: const Text('续费当前套餐'),
                  ),
                ),
              if (!sub.hasNoPlan) const SizedBox(width: 12),
              // 购买/更改套餐（R6.5/R6.6），描边品牌按钮。
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _openPlans(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.primary,
                    side: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.4), width: 1.6),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(XbTokens.rButton)),
                  ),
                  child: Text(sub.hasNoPlan ? '购买套餐' : '购买 / 更改套餐'),
                ),
              ),
            ],
          ),
        ),
        // 流量重置告警卡（原型 .resetcard，仅 ≥90% 显示）。
        if (showReset) ...[
          const SizedBox(height: 12),
          _ResetCard(pctInt: pctInt, onTap: () => _openReset(context, sub)),
        ],
      ],
    );
  }

  // ◇ 复用形态 B 套餐页（不经 adapter）。
  void _openPlans(BuildContext context) {
    xbPush(context, const PlanListPage(),
        brandColor: xbBrandColor());
  }

  /// 续费当前套餐（R6.4）：与「购买/更改」走同一模式——**立即跳转**，由 [PlanRenewLoader]
  /// 自己拉套餐 + 锁定当前套餐 + 转圈（XbAsyncView），交互统一（不在本页预拉 + 弹遮罩）。
  void _openRenew(BuildContext context) {
    final id = sub.planId;
    if (id == null) {
      // 异常：有套餐但无 planId → 回退购买/更改列表。
      xbPush(context, const PlanListPage(), brandColor: xbBrandColor());
      return;
    }
    xbPush(context, PlanRenewLoader(planId: id), brandColor: xbBrandColor());
  }

  void _openReset(BuildContext context, XbDomainSubscription sub) {
    xbPush(
      context,
      ResetTrafficPage(planId: sub.planId!, planName: sub.planName),
      brandColor: xbBrandColor(),
    );
  }
}

/// 流量重置告警卡（原型 .resetcard，仅用量 ≥90% 显示，R6.3）。
class _ResetCard extends StatelessWidget {
  const _ResetCard({required this.pctInt, required this.onTap});

  final int pctInt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 告警色：原型 .resetcard 用 --warn 琥珀（非品牌红/error 红）。
    const warn = XbTokens.warn;
    final cardBg = Color.alphaBlend(warn.withValues(alpha: 0.10), scheme.surfaceContainerLowest);
    return Material(
      color: cardBg,
      borderRadius: BorderRadius.circular(XbTokens.rMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(XbTokens.rMd),
            border: Border.all(color: warn.withValues(alpha: 0.32)),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_rounded, color: warn, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '流量即将用尽（已用 $pctInt%）',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '可购买流量重置包，立即恢复本月可用流量',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                decoration: BoxDecoration(
                  color: warn,
                  borderRadius: BorderRadius.circular(XbTokens.rSm),
                ),
                child: const Text(
                  '流量重置',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 加载骨架（已登录未就绪，R6.9）—— 原型：顶部琥珀同步条 + 白底骨架卡（shimmer）。
class _AccountSkeleton extends StatelessWidget {
  const _AccountSkeleton({this.bannerText});

  /// 顶部同步横幅文案（null → XbSyncBanner 默认「正在同步账号与套餐信息…」；
  /// 重试态传「正在刷新服务，请稍候…」，原型 11d）。
  final String? bannerText;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部同步条（原型 .syncbar）。
        bannerText != null ? XbSyncBanner(text: bannerText!) : const XbSyncBanner(),
        const SizedBox(height: 12),
        // 白底骨架卡（原型 .plancmp.plan-skel，紧凑无头像）。
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(XbTokens.rCard),
            border: Border.all(color: t.line),
            boxShadow: t.shadow1,
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 套餐名行（无头像）。
              XbSkeletonBar(widthFactor: 0.55, height: 15),
              SizedBox(height: 11),
              // 流量数字行。
              XbSkeletonBar(widthFactor: 0.46, height: 22),
              SizedBox(height: 11),
              // 进度条。
              XbSkeletonBar(widthFactor: 1, height: 10, radius: 6),
              SizedBox(height: 11),
              // 到期行。
              XbSkeletonBar(widthFactor: 0.68, height: 13),
              SizedBox(height: 7),
              // 重置行。
              XbSkeletonBar(widthFactor: 0.62, height: 13),
            ],
          ),
        ),
        // 续费/购买按钮行（加载态禁用，原型 .brow.dis 半透明）。
        const SizedBox(height: 12),
        const _DisabledPlanActions(),
      ],
    );
  }
}

/// 加载态禁用按钮行（原型 booting `.brow.dis`：续费/购买都置灰禁用）。
class _DisabledPlanActions extends StatelessWidget {
  const _DisabledPlanActions();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: Opacity(
        opacity: 0.5,
        child: Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: null,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(XbTokens.rButton)),
                ),
                child: const Text('续费当前套餐'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.primary,
                  side: BorderSide(
                      color: scheme.primary.withValues(alpha: 0.4), width: 1.6),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(XbTokens.rButton)),
                ),
                child: const Text('购买 / 更改套餐'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 账号卡加载失败态（原型 `.plan-error`，11c）：白底卡 + 圆形红云图标 + 标题 + 出路说明 +
/// 描边「重新加载」按钮。重试 = `ref.invalidate(userProfileProvider)` → 只重发 getSubscription
/// （不重新竞速、不重拉节点订阅），故文案强调「不影响连接与节点」。下方账户/应用菜单仍可用。
class _AccountErrorCard extends StatelessWidget {
  const _AccountErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    // 横向紧凑布局（与紧凑账号卡等高）：左圆图标 + 中标题/说明 + 右描边重试。
    return Container(
      constraints: const BoxConstraints(minHeight: 118),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(XbTokens.rLg),
        border: Border.all(color: t.line),
        boxShadow: t.shadow1,
      ),
      child: Row(
        children: [
          // 圆形图标容器（红云，--bad 10% 柔底）。
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color.alphaBlend(
                  XbTokens.bad.withValues(alpha: 0.10), t.sfc),
            ),
            child: const Icon(Icons.cloud_off_rounded,
                size: 25, color: XbTokens.bad),
          ),
          const SizedBox(width: 14),
          // 标题 + 一行说明。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('账号信息加载失败',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600, color: t.on)),
                const SizedBox(height: 3),
                Text(
                  '请检查网络后重试，期间不影响连接与节点使用',
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: t.onv),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 描边「重新加载」按钮。
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('重新加载'),
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.primary,
              side: BorderSide(
                  color: scheme.primary.withValues(alpha: 0.40), width: 1.6),
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(XbTokens.rMd)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 游客引导卡（R6.10）—— 原型灰渐变卡（与账号卡同布局，未登录用灰色，白字 + 白登录按钮）。
class _GuestCard extends StatelessWidget {
  const _GuestCard({this.onTapLogin});

  final VoidCallback? onTapLogin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final white70 = Colors.white.withValues(alpha: 0.88);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XbTokens.rLg),
        // 原型 mineGuest 灰渐变（#8a909e → #5a606e）。
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF8A909E), Color(0xFF5A606E)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x4D3C4250),
            blurRadius: 44,
            offset: Offset(0, 22),
            spreadRadius: -16,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 未登录标题（无头像，紧凑版）。
          const Text('未登录',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
          const SizedBox(height: 4),
          Text('登录后同步专属节点与套餐',
              style: TextStyle(fontSize: 12, color: white70)),
          const SizedBox(height: 13),
          // 白底登录按钮（灰卡上的高对比 CTA）。
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onTapLogin,
              icon: const Icon(Icons.login, size: 18),
              label: const Text('登录 / 注册'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置入口区（原型分「账户 / 应用」两组，R6.8/R6.11）。
class _SettingsSection extends ConsumerWidget {
  const _SettingsSection({required this.isGuest});

  final bool isGuest;

  /// 退出登录二次确认（破坏性操作，原型 15b）：destructive 红确认键。确认后执行登出编排
  /// （清 token/profile + 服务端撤销，永不抛）+ 全程 loading 遮罩（编排有网络耗时，避免无反馈）。
  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final ok = await xbConfirm(
      context,
      title: '退出登录',
      message: '退出后需重新登录才能连接和管理套餐，确定退出吗？',
      confirmLabel: '退出登录',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    // 登出编排有网络耗时（服务端撤销 token）→ 弹不可关闭 loading，完成后自动消失（切游客态重建树）。
    // 走 xbShowDialog 套品牌主题（裸 showDialog 挂根 Navigator 会逃逸 formA 主题，§check-xb-theme）。
    xbShowDialog<void>(
      context: context,
      brandColor: xbBrandColor(),
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await ref.read(authStateProvider.notifier).logout();
    } finally {
      // logout 永不抛；切到游客态后关掉 loading（用根 navigator pop 掉 loading dialog）。
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 账户组 ──
        const XbGroupLabel('账户'),
        XbListCard(
          rows: [
            XbListRow(
              icon: Icons.receipt_long,
              label: '我的订单',
              badge: isGuest ? '登录后可见' : null,
              showChevron: !isGuest,
              onTap: isGuest
                  ? null
                  : () => xbPush(context, const OrderListPage(),
                      brandColor: xbBrandColor()),
            ),
          ],
        ),
        // ── 应用组 ──
        const XbGroupLabel('应用'),
        XbListCard(
          rows: [
            XbListRow(
              icon: Icons.settings,
              label: '设置',
              // 设置 → 形态 A 风格设置页（组件库列表 → FlClash 原生子页，R6.8）。
              onTap: () => xbPush(context, const XbSettingsPage(),
                  brandColor: xbBrandColor()),
            ),
            const _AboutRow(),
            if (!isGuest)
              XbListRow(
                icon: Icons.logout,
                label: '退出登录',
                danger: true,
                showChevron: false,
                // 破坏性操作二次确认（与「取消订单」一致），确认后执行登出（◇ 复用形态 B 编排，R6.11）。
                onTap: () => _confirmLogout(context, ref),
              ),
          ],
        ),
      ],
    );
  }
}

/// 「关于」条目：显示 MyClient 自有产品版本 + 构建时间戳（`v0.0.1-{tag}`）。
/// 注意与「设置 → 关于」（FlClash 原生页，显示底座版本 0.8.93）不同源。
class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    return XbListRow(
      icon: Icons.info_outline,
      label: '关于',
      badge: myClientVersionLabel(),
    );
  }
}
