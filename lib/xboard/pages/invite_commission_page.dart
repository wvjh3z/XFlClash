/// 邀请返佣页（form-a · 原型「邀请返佣」屏）。
///
/// 从「我的」Tab → 账户组「邀请返佣」push 进入（需登录）。
/// 内容：佣金/账户余额卡（划转 / 提现）· 数据统计 · 分享链接 · 邀请码 · 返佣流程 · 返佣记录入口。
///
/// **数据**：`inviteInfoProvider`（无码自动生成）+ `shareLinkProvider`（分享地址）。永不抛（XbResult）。
/// **复用框架**：XbBrandScaffold / XbAsyncView(骨架) / XbCard / XbListCard / xbShowDialog / xbToast。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_invite.dart';
import '../models/xb_result.dart';
import '../providers/invite_provider.dart';
import '../providers/share_link_provider.dart';
import '../providers/xboard_providers.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor, xbToast;
import '../widgets/xb_share_links.dart';
import '../widgets/xb_theme.dart' show xbPush, xbShowDialog, XbTokens;
import '../widgets/xb_ui_kit.dart' show XbBrandScaffold;
import 'commission_records_page.dart';

/// 提现门槛（元，前端写死；后端另按 commission_withdraw_limit 校验）。
const double kWithdrawMinYuan = 200;

/// 后端提现方式白名单（Dict::WITHDRAW_METHOD_WHITELIST_DEFAULT）。
const List<String> kWithdrawMethods = ['支付宝', 'USDT', 'Paypal'];

class InviteCommissionPage extends ConsumerWidget {
  const InviteCommissionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const XbBrandScaffold(
      title: '邀请返佣',
      maxContentWidth: 1000,
      body: _InviteBody(),
    );
  }
}

class _InviteBody extends ConsumerWidget {
  const _InviteBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(inviteInfoProvider);
    // 分享链接是另一个 guest 异步源。之前只 gate inviteInfo → inviteInfo 一快返回骨架就消失，
    // 分享卡还在单独加载、随后才弹入（两现象同根）。把它纳入加载门：两者都就绪才出内容，骨架覆盖
    // 整段加载、分享卡与其余卡同时出现。分享失败/禁用也算就绪（不阻塞页面，分享区自隐）。
    final shareAsync = ref.watch(shareLinkProvider);
    final shareSettled = !shareAsync.isLoading;
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(inviteInfoProvider);
        ref.invalidate(shareLinkProvider);
        // 等两者本次重拉都落定再收起转圈；失败吞掉（错误态由 XbAsyncView 接管，不重复弹）。
        try {
          await Future.wait([
            ref.read(inviteInfoProvider.future),
            ref.read(shareLinkProvider.future),
          ]);
        } catch (_) {
          // 错误由 XbAsyncView 的 error 态 / 分享区自隐处理，此处仅需等待 future 落定。
        }
      },
      child: XbAsyncView(
        // 主数据加载中 或 分享链接尚未落定 → 都显示骨架（覆盖整段加载）。
        loading: async.isLoading || !shareSettled,
        // 错误只 gate 主数据：分享失败不该挡住整页（分享区会自隐）。
        error: async.hasError ? async.error : null,
        errorFallback: '加载邀请信息失败',
        skeleton: XbSkeletonKind.invite,
        onRetry: () {
          ref.invalidate(inviteInfoProvider);
          ref.invalidate(shareLinkProvider);
        },
        builder: (context) => _content(context, ref, async.requireValue),
      ),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, XbInviteInfo info) {
    return LayoutBuilder(
      builder: (context, c) {
        // 桌面双栏（原型屏29）：左=余额卡+统计+确认中提示+返佣记录入口；右=分享链接+邀请码+返佣流程。
        // 窄窗 / 移动端单列（原顺序）。
        if (c.maxWidth >= 760) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _BalanceCard(info: info),
                      const SizedBox(height: 13),
                      _StatsGrid(info: info),
                      const _PendingTip(),
                      const SizedBox(height: 14),
                      const XbGroupLabel('返佣记录'),
                      _recordsEntry(context),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ShareLinksSection(code: info.code),
                      const SizedBox(height: 4),
                      _InviteCodeCard(code: info.code),
                      const SizedBox(height: 4),
                      const _FlowSection(),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            _BalanceCard(info: info),
            const SizedBox(height: 13),
            _StatsGrid(info: info),
            const _PendingTip(),
            const SizedBox(height: 4),
            _ShareLinksSection(code: info.code),
            const SizedBox(height: 4),
            _InviteCodeCard(code: info.code),
            const SizedBox(height: 4),
            const _FlowSection(),
            const SizedBox(height: 14),
            const XbGroupLabel('返佣记录'),
            _recordsEntry(context),
          ],
        );
      },
    );
  }

  /// 返佣记录入口卡（单列 / 双栏共用）。
  Widget _recordsEntry(BuildContext context) {
    return XbListCard(rows: [
      XbListRow(
        icon: Icons.receipt_long,
        label: '查看返佣记录',
        onTap: () => xbPush(context, const CommissionRecordsPage(),
            brandColor: xbBrandColor()),
      ),
    ]);
  }
}

// ───────────────────────── 佣金 / 账户余额卡 ─────────────────────────

class _BalanceCard extends ConsumerWidget {
  const _BalanceCard({required this.info});
  final XbInviteInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = Theme.of(context).colorScheme.primary;
    final hsl = HSLColor.fromColor(brand);
    final brandDark =
        hsl.withLightness((hsl.lightness * 0.78).clamp(0.0, 1.0)).toColor();
    final brandLight =
        hsl.withLightness((hsl.lightness * 1.18).clamp(0.0, 1.0)).toColor();
    final canWithdraw = info.commissionBalanceYuan >= kWithdrawMinYuan;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XbTokens.rLg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [brandLight, brand, brandDark],
        ),
        boxShadow: [
          BoxShadow(
            color: brand.withValues(alpha: 0.45),
            blurRadius: 30,
            offset: const Offset(0, 16),
            spreadRadius: -14,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 双列余额：佣金余额（主）+ 账户余额（次，竖分隔线）。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 57,
                  child: _balanceCol(
                    icon: Icons.savings_outlined,
                    label: '佣金余额',
                    amount: info.commissionBalanceYuan,
                    big: true,
                  ),
                ),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  color: Colors.white.withValues(alpha: 0.22),
                ),
                Expanded(
                  flex: 43,
                  child: _balanceCol(
                    icon: Icons.account_balance_wallet_outlined,
                    label: '账户余额',
                    amount: info.accountBalanceYuan,
                    big: false,
                    sub: '购买套餐可抵扣',
                  ),
                ),
              ],
            ),
          ),
          // 操作按钮组：划转到余额（白实心）+ 佣金提现（描边）。
          // 「?」说明角标浮于按钮组上方的留白区（原型 .invbal-info top:-26，浮在按钮上方、
          // 与按钮不重叠）。把留白纳入 Stack 内，角标落在 Stack 边界内 → 整块可点（不再依赖
          // Clip.none 渲染到界外的不可点区域，既不重叠也好点）。
          Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 26),
                  Row(
                    children: [
                      Expanded(
                        child: _balanceBtn(
                          context,
                          icon: Icons.swap_horiz,
                          label: '划转到余额',
                          solid: true,
                          brand: brand,
                          onTap: () => _openTransfer(context, ref),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: _balanceBtn(
                          context,
                          icon: canWithdraw ? Icons.account_balance : Icons.lock,
                          label: canWithdraw
                              ? '佣金提现'
                              : '满 ¥${kWithdrawMinYuan.toStringAsFixed(0)} 可提现',
                          solid: false,
                          brand: brand,
                          disabled: !canWithdraw,
                          onTap:
                              canWithdraw ? () => _openWithdraw(context, ref) : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              // 「?」说明角标：贴右上角，落在上方 24px 留白内（与按钮齐平但不重叠）。
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openWithdrawRule(context),
                  child: const Padding(
                    padding: EdgeInsets.only(left: 14, bottom: 2),
                    child: _HelpBadge(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _balanceCol({
    required IconData icon,
    required String label,
    required double amount,
    required bool big,
    String? sub,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.92)),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 12, color: Colors.white.withValues(alpha: 0.9))),
          ],
        ),
        const SizedBox(height: 6),
        // 金额：FittedBox(scaleDown) 保证能完整显示（够位时原尺寸、超宽时整体缩放，绝不省略号）；
        // 货币符号小字（原型 .invbal-num .cur 17px / 数字 30px）。
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: '¥',
                style: TextStyle(
                  fontSize: big ? 17 : 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.92),
                ),
              ),
              TextSpan(
                text: amount.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: big ? 30 : 25,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -0.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ]),
            maxLines: 1,
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: 7),
          Text(sub,
              style: TextStyle(
                  fontSize: 10.5, color: Colors.white.withValues(alpha: 0.8))),
        ],
      ],
    );
  }

  Widget _balanceBtn(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool solid,
    required Color brand,
    VoidCallback? onTap,
    bool disabled = false,
  }) {
    final Color bg;
    final Color fg;
    BoxBorder? border;
    if (disabled) {
      bg = Colors.white.withValues(alpha: 0.10);
      fg = Colors.white.withValues(alpha: 0.55);
      border = Border.all(color: Colors.white.withValues(alpha: 0.22), width: 1.5);
    } else if (solid) {
      bg = Colors.white.withValues(alpha: 0.94);
      fg = brand;
    } else {
      bg = Colors.white.withValues(alpha: 0.14);
      fg = Colors.white;
      border = Border.all(color: Colors.white.withValues(alpha: 0.5), width: 1.5);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        child: Ink(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(XbTokens.rMd),
            border: border,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600, color: fg)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openTransfer(BuildContext context, WidgetRef ref) {
    xbShowDialog<void>(
      context: context,
      brandColor: xbBrandColor(),
      builder: (_) => _TransferDialog(info: info),
    );
  }

  void _openWithdraw(BuildContext context, WidgetRef ref) {
    xbShowDialog<void>(
      context: context,
      brandColor: xbBrandColor(),
      builder: (_) => _WithdrawDialog(info: info),
    );
  }

  void _openWithdrawRule(BuildContext context) {
    xbShowDialog<void>(
      context: context,
      brandColor: xbBrandColor(),
      builder: (_) => const _WithdrawRuleDialog(),
    );
  }
}

/// 提现按钮右上角「?」角标（半透明白底 + help 图标）。抽成独立 widget 以便 const 化。
class _HelpBadge extends StatelessWidget {
  const _HelpBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.28),
      ),
      child: const Icon(Icons.help_outline, size: 15, color: Colors.white),
    );
  }
}

// ───────────────────────── 数据统计 2×2 ─────────────────────────
class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.info});
  final XbInviteInfo info;

  @override
  Widget build(BuildContext context) {
    final cells = [
      _stat(context, Icons.group, '已注册用户', '${info.registeredCount}', unit: '人'),
      _stat(context, Icons.hourglass_top, '确认中佣金', xbYuan(info.pendingYuan)),
      _stat(context, Icons.savings, '累计获得佣金', xbYuan(info.totalYuan)),
      _stat(context, Icons.percent, '返佣比例', '${info.commissionRate}', unit: '%'),
    ];
    return Column(
      children: [
        Row(children: [
          Expanded(child: cells[0]),
          const SizedBox(width: 10),
          Expanded(child: cells[1]),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: cells[2]),
          const SizedBox(width: 10),
          Expanded(child: cells[3]),
        ]),
      ],
    );
  }

  Widget _stat(BuildContext context, IconData icon, String label, String num,
      {String? unit}) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        border: Border.all(color: t.line),
        boxShadow: t.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Color.alphaBlend(brand.withValues(alpha: 0.10), t.sfc),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 15, color: brand),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.onv)),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: num,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: t.on,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (unit != null)
                TextSpan(
                  text: unit,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500, color: t.onv),
                ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _PendingTip extends StatelessWidget {
  const _PendingTip();

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: brand),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '「确认中佣金」为好友新订单产生的待确认返佣，将在 3 天后自动确认到账并计入佣金余额。',
              style: TextStyle(fontSize: 11.5, height: 1.6, color: t.onv),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 分享链接 ─────────────────────────

class _ShareLinksSection extends ConsumerWidget {
  const _ShareLinksSection({this.code});

  /// 我的邀请码（复制分享链接时附带进文案；可空）。
  final String? code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(shareLinkProvider);
    final link = async.asData?.value;
    // 分享地址未就绪 / 未配置 → 不展示分享区块（邀请页核心是邀请码，分享地址是附加）。
    if (link == null || !link.enabled) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const XbGroupLabel('分享链接 · 复制下载各种平台的客户端'),
        XbShareLinksCard(
          primaryUrl: link.primaryUrl,
          backupUrl: link.backupUrl,
          inviteCode: code,
        ),
      ],
    );
  }
}

// ───────────────────────── 邀请码卡 ─────────────────────────

class _InviteCodeCard extends StatelessWidget {
  const _InviteCodeCard({required this.code});
  final String? code;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    final hasCode = code != null && code!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const XbGroupLabel('我的邀请码'),
        XbCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.confirmation_number_outlined, size: 16, color: brand),
                  const SizedBox(width: 7),
                  Text('我的邀请码',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: t.onv)),
                  const Spacer(),
                  if (hasCode)
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        color: XbTokens.ok.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle,
                              size: 12, color: XbTokens.ok),
                          SizedBox(width: 3),
                          Text('已生效',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: XbTokens.ok)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Color.alphaBlend(brand.withValues(alpha: 0.06), t.sfc),
                  borderRadius: BorderRadius.circular(XbTokens.rMd),
                  border: Border.all(
                      color: Color.alphaBlend(
                          brand.withValues(alpha: 0.16), t.line)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        hasCode ? code! : '生成中…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 3,
                          // 真实邀请码常含大小写字母 + 数字混排，比例字体下宽窄不一显得杂乱；
                          // 等宽字体让每个字符同宽，对齐整齐、可读性更好（原型 .code 同样定宽观感）。
                          fontFamily: 'monospace',
                          fontFamilyFallback: const [
                            'Menlo',
                            'Consolas',
                            'DejaVu Sans Mono',
                            'Courier New',
                          ],
                          color: t.on,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: hasCode
                          ? () {
                              Clipboard.setData(ClipboardData(text: code!));
                              xbToast(context, '邀请码已复制');
                            }
                          : null,
                      icon: const Icon(Icons.content_copy, size: 15),
                      label: const Text('复制'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 15),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 11),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lightbulb_outline,
                      size: 14, color: XbTokens.warn),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text('该邀请码可以无限次使用',
                        style: TextStyle(
                            fontSize: 11.5, height: 1.6, color: t.onv)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── 返佣流程 5 步 ─────────────────────────

class _FlowSection extends StatelessWidget {
  const _FlowSection();

  static const _steps = [
    (Icons.share, '分享'),
    (Icons.download, '下载'),
    (Icons.person_add_alt, '注册'),
    (Icons.shopping_cart_outlined, '购买'),
    (Icons.redeem, '返佣'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const XbGroupLabel('返佣流程'),
        XbCard(
          child: Column(
            children: [
              Row(
                children: [
                  for (var i = 0; i < _steps.length; i++) ...[
                    _step(context, _steps[i].$1, _steps[i].$2,
                        last: i == _steps.length - 1),
                    if (i != _steps.length - 1)
                      Expanded(
                        child: Container(
                          height: 2,
                          margin: const EdgeInsets.only(bottom: 22),
                          color: Color.alphaBlend(
                              brand.withValues(alpha: 0.18), t.line),
                        ),
                      ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              Divider(height: 1, thickness: 1, color: t.hair),
              const SizedBox(height: 13),
              Text.rich(
                TextSpan(
                  style: TextStyle(fontSize: 12, height: 1.7, color: t.onv),
                  children: [
                    const TextSpan(text: '好友通过你的链接'),
                    TextSpan(
                        text: '下载',
                        style: TextStyle(color: t.on, fontWeight: FontWeight.w600)),
                    const TextSpan(text: '客户端、'),
                    TextSpan(
                        text: '注册',
                        style: TextStyle(color: t.on, fontWeight: FontWeight.w600)),
                    const TextSpan(text: '时填写你的邀请码并成功'),
                    TextSpan(
                        text: '购买',
                        style: TextStyle(color: t.on, fontWeight: FontWeight.w600)),
                    const TextSpan(text: '套餐后，你将获得订单金额一定比例的返佣。'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _step(BuildContext context, IconData icon, String label,
      {required bool last}) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: last
                ? brand
                : Color.alphaBlend(brand.withValues(alpha: 0.09), t.sfc),
            border: last
                ? null
                : Border.all(
                    color: Color.alphaBlend(
                        brand.withValues(alpha: 0.22), t.line),
                    width: 1.5),
          ),
          child: Icon(icon, size: 20, color: last ? Colors.white : brand),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: t.on)),
      ],
    );
  }
}

// ═════════════════════════ 弹窗 ═════════════════════════

/// 佣金划转弹窗：佣金余额 → 账户余额（可指定金额，默认全部）。
class _TransferDialog extends ConsumerStatefulWidget {
  const _TransferDialog({required this.info});
  final XbInviteInfo info;

  @override
  ConsumerState<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<_TransferDialog> {
  late final TextEditingController _amount = TextEditingController(
      text: widget.info.commissionBalanceYuan.toStringAsFixed(2));
  bool _submitting = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final yuan = double.tryParse(_amount.text.trim());
    if (yuan == null || yuan <= 0) {
      xbToast(context, '请输入有效的划转金额');
      return;
    }
    if (yuan > widget.info.commissionBalanceYuan + 0.001) {
      xbToast(context, '划转金额不能超过佣金余额');
      return;
    }
    setState(() => _submitting = true);
    final result =
        await ref.read(xboardServiceProvider).transferCommissionToBalance(yuan);
    if (!mounted) return;
    switch (result) {
      case XbSuccess():
        ref.invalidate(inviteInfoProvider);
        Navigator.of(context).pop();
        xbToast(context, '划转成功，已转入账户余额');
      case XbFailure(:final error):
        setState(() => _submitting = false);
        xbToast(context, resolveErrorText(error, fallback: '划转失败，请重试'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return AlertDialog(
      backgroundColor: t.sf2,
      title: const Column(mainAxisSize: MainAxisSize.min, children: [
        Text('划转到账户余额', textAlign: TextAlign.center),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('佣金余额划转到账户余额后，可在购买 / 续费套餐时直接抵扣。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.5, color: t.onv)),
          const SizedBox(height: 16),
          _TransferRow(
            from: widget.info.commissionBalanceYuan,
            to: widget.info.accountBalanceYuan,
          ),
          const SizedBox(height: 12),
          // 划转金额：原型 .xfer-field —— 紧凑 50px 描边行（¥ 前缀 + 内嵌无边框输入 + 右侧「全部」），
          // 而非 Material 浮动标签输入框（后者更高、观感与原型不符）。
          _CompactFieldShell(
            child: Row(
              children: [
                Text('¥', style: TextStyle(fontSize: 14.5, color: t.onv)),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _amount,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: TextStyle(fontSize: 14.5, color: t.on),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      contentPadding: EdgeInsets.zero,
                      // 全部边框态置空：外层 _CompactFieldShell 已提供中性描边；不显式关闭则
                      // 全局 inputDecorationTheme 的 focusedBorder(品牌红) 会在聚焦时冒出红框。
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      hintText: '划转金额',
                      hintStyle: TextStyle(fontSize: 14.5, color: t.onv),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 「全部」：一键填入全部佣金余额（原型 .xfer-all 品牌色链接）。
                GestureDetector(
                  onTap: () => _amount.text =
                      widget.info.commissionBalanceYuan.toStringAsFixed(2),
                  child: Text('全部',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: brand)),
                ),
              ],
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: [_DialogActions(
        confirmLabel: '确认划转',
        submitting: _submitting,
        onConfirm: _submit,
      )],
    );
  }
}

/// 佣金提现弹窗：整笔提现（金额不可改）+ 收款方式 + 收款账户。
class _WithdrawDialog extends ConsumerStatefulWidget {
  const _WithdrawDialog({required this.info});
  final XbInviteInfo info;

  @override
  ConsumerState<_WithdrawDialog> createState() => _WithdrawDialogState();
}

class _WithdrawDialogState extends ConsumerState<_WithdrawDialog> {
  String _method = kWithdrawMethods.first;
  late final TextEditingController _account = TextEditingController();
  bool _submitting = false;

  /// 可选收款方式列表。默认后端白名单常量；接口可用时由 [withdrawMethodsProvider] 覆盖。
  List<String> get _methods {
    final fromApi = ref.watch(withdrawMethodsProvider);
    return fromApi.isNotEmpty ? fromApi : kWithdrawMethods;
  }

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final account = _account.text.trim();
    if (account.isEmpty) {
      xbToast(context, '请输入收款账户');
      return;
    }
    // 收款方式以当前可选列表为准（API 列表可能与本地默认不同，未选中时取首项）。
    final methods = _methods;
    final method = methods.contains(_method) ? _method : methods.first;
    setState(() => _submitting = true);
    final result = await ref
        .read(xboardServiceProvider)
        .withdrawCommission(method: method, account: account);
    if (!mounted) return;
    switch (result) {
      case XbSuccess():
        Navigator.of(context).pop();
        xbToast(context, '提现申请已提交，请等待后台审核');
      case XbFailure(:final error):
        setState(() => _submitting = false);
        xbToast(context, resolveErrorText(error, fallback: '提现失败，请重试'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return AlertDialog(
      backgroundColor: t.sf2,
      title: const Column(mainAxisSize: MainAxisSize.min, children: [
        Text('佣金提现', textAlign: TextAlign.center),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '提现须符合提现条件，否则不予受理。经后台审核后 3 个工作日将佣金打款到你的收款账户，如果是支付宝提现，请联系在线客服提供收款码。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: t.onv),
          ),
          const SizedBox(height: 16),
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              color: t.sfc,
              borderRadius: BorderRadius.circular(XbTokens.rMd),
              border: Border.all(color: t.line),
            ),
            child: Row(
              children: [
                Text('提现金额（整笔佣金）',
                    style: TextStyle(fontSize: 14, color: t.onv)),
                const Spacer(),
                Text(xbYuan(widget.info.commissionBalanceYuan),
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: t.on,
                        fontFeatures:
                            const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // 收款方式：原型 .field — 50px 高、1.5px 描边、sfc 底、r-md 圆角的紧凑行
          // （而非 Material 浮动标签输入框，后者更高且观感与原型不符 → 之前「框太长」）。
          _CompactFieldShell(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _methods.contains(_method) ? _method : _methods.first,
                isExpanded: true,
                isDense: true,
                hint: Text('收款方式',
                    style: TextStyle(fontSize: 14.5, color: t.onv)),
                icon: Icon(Icons.expand_more, size: 20, color: t.onv),
                style: TextStyle(fontSize: 14.5, color: t.on),
                dropdownColor: t.sf2,
                items: [
                  for (final m in _methods)
                    DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (v) => setState(() => _method = v ?? _method),
              ),
            ),
          ),
          const SizedBox(height: 11),
          // 收款账户：同 .field 紧凑行，内嵌无边框 TextField。
          _CompactFieldShell(
            child: TextField(
              controller: _account,
              style: TextStyle(fontSize: 14.5, color: t.on),
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
                // 全部边框态置空（同划转金额框）：避免聚焦时全局 focusedBorder(品牌红) 冒红框；
                // 中性描边由外层 _CompactFieldShell 提供。
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                hintText: '收款账户',
                hintStyle: TextStyle(fontSize: 14.5, color: t.onv),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 14, color: t.onv),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '提现为整笔佣金，金额不可拆分；门槛 ¥${kWithdrawMinYuan.toStringAsFixed(0)}，到账时间以后台审核为准',
                  style: TextStyle(fontSize: 11, height: 1.5, color: t.onv),
                ),
              ),
            ],
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: [_DialogActions(
        confirmLabel: '提交申请',
        submitting: _submitting,
        onConfirm: _submit,
      )],
    );
  }
}

/// 佣金提现说明弹窗（点佣金卡右上角「?」）。
class _WithdrawRuleDialog extends StatelessWidget {
  const _WithdrawRuleDialog();

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    Widget rule(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.check_circle, size: 17, color: XbTokens.ok),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text,
                    style: TextStyle(fontSize: 13, height: 1.6, color: t.on)),
              ),
            ],
          ),
        );
    return AlertDialog(
      backgroundColor: t.sf2,
      title: const Column(mainAxisSize: MainAxisSize.min, children: [
        Text('佣金提现说明', textAlign: TextAlign.center),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('满足以下条件后即可申请佣金提现：',
              style: TextStyle(fontSize: 13, color: t.onv)),
          const SizedBox(height: 4),
          rule('佣金余额 ≥ ¥${kWithdrawMinYuan.toStringAsFixed(0)}'),
          rule('已购买用户达到 20 人'),
          const SizedBox(height: 8),
          Text('未达门槛时，可先将佣金「划转到余额」，用于购买 / 续费套餐抵扣（划转无门槛）。',
              style: TextStyle(fontSize: 12.5, height: 1.6, color: t.onv)),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: [
        SizedBox(
          width: double.infinity,
          height: 46,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ),
      ],
    );
  }
}

// 弹窗公共小部件。

/// 原型 `.field` 紧凑输入行外壳：50px 高、1.5px 描边、sfc 底、r-md 圆角。
/// 包裹 Dropdown / TextField，替代 Material 浮动标签输入框（后者更高，观感不符原型）。
class _CompactFieldShell extends StatelessWidget {
  const _CompactFieldShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 15),
      decoration: BoxDecoration(
        color: t.sfc,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        border: Border.all(color: t.line, width: 1.5),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.from, required this.to});
  final double from;
  final double to;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    Widget col(String label, double amount, Color color) => Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: t.onv)),
              const SizedBox(height: 3),
              Text(xbYuan(amount),
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: t.sfc,
        borderRadius: BorderRadius.circular(XbTokens.rMd),
        border: Border.all(color: t.line),
      ),
      child: Row(
        children: [
          col('佣金余额', from, t.on),
          Icon(Icons.arrow_forward, size: 20, color: t.onv),
          col('账户余额', to, brand),
        ],
      ),
    );
  }
}

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.confirmLabel,
    required this.submitting,
    required this.onConfirm,
  });
  final String confirmLabel;
  final bool submitting;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: submitting ? null : () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: t.sfc,
                foregroundColor: t.on,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(XbTokens.rMd)),
              ),
              child: const Text('取消'),
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: submitting ? null : onConfirm,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(XbTokens.rMd)),
              ),
              child: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(confirmLabel),
            ),
          ),
        ),
      ],
    );
  }
}
