/// 邀请返佣页（form-a · 原型「邀请返佣」屏）。
///
/// 从「我的」Tab → 账户组「邀请返佣」push 进入（需登录）。
/// 内容：佣金/账户余额卡（划转 / 提现）· 数据统计 · 分享链接 · 邀请码 · 返佣流程 · 返佣记录入口。
///
/// **数据**：`inviteInfoProvider`（无码自动生成）+ `shareLinkProvider`（分享地址）。永不抛（XbResult）。
/// **复用框架**：XbBrandScaffold / XbAsyncView(骨架) / XbCard / XbListCard / xbShowDialog / xbToast。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_invite.dart';
import '../models/xb_result.dart';
import '../models/xb_domain_error.dart';
import '../providers/auth_state_provider.dart';
import '../providers/invite_provider.dart';
import '../providers/share_link_provider.dart';
import '../providers/xboard_providers.dart';
import '../services/withdraw_eligibility.dart' show withdrawPaidRecordCount;
import '../util/error_text.dart';
import '../util/format.dart';
import '../util/money_input.dart';
import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_feedback.dart' show xbBrandColor, xbToast;
import '../widgets/xb_share_links.dart';
import '../widgets/xb_theme.dart'
    show xbDialogRoute, xbPush, xbShowDialog, XbTokens;
import '../widgets/xb_ui_kit.dart' show XbBrandScaffold, XbGradientAction;
import 'commission_records_page.dart';
import 'withdraw_commission_dialog.dart';

final _withdrawDialogs = Expando<DialogRoute<void>>();

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
        ref.invalidate(commissionRecordsProvider);
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
        builder: (context) => _content(context, async.requireValue),
      ),
    );
  }

  Widget _content(BuildContext context, XbInviteInfo info) {
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
                      const _RecordsEntry(),
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
                      _FlowSection(rate: info.commissionRate),
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
            _FlowSection(rate: info.commissionRate),
            const SizedBox(height: 14),
            const XbGroupLabel('返佣记录'),
            const _RecordsEntry(),
          ],
        );
      },
    );
  }
}

/// 只有记录入口订阅首批流水；网络异常不阻挡邀请信息或点入详情。
class _RecordsEntry extends ConsumerWidget {
  const _RecordsEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(commissionRecordsProvider);
    final rows = records.isLoading ? null : records.asData?.value;
    final count = rows == null ? null : withdrawPaidRecordCount(rows);
    final tokens = XbTokens.of(context);
    return XbListCard(
      rows: [
        XbListRow(
          icon: Icons.receipt_long,
          label: '查看返佣记录',
          trailing: count == null
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      count < commissionRecordsPageSize
                          ? '共 $count 条'
                          : '至少 $count 条',
                      style: TextStyle(fontSize: 12.5, color: tokens.onv),
                    ),
                    Icon(Icons.chevron_right, color: tokens.onv, size: 20),
                  ],
                ),
          onTap: () => xbPush(
            context,
            const CommissionRecordsPage(),
            brandColor: xbBrandColor(),
          ),
        ),
      ],
    );
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
    final brandDark = hsl
        .withLightness((hsl.lightness * 0.78).clamp(0.0, 1.0))
        .toColor();
    final brandLight = hsl
        .withLightness((hsl.lightness * 1.18).clamp(0.0, 1.0))
        .toColor();
    return Container(
      clipBehavior: Clip.antiAlias,
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
      child: Stack(children: [
        Positioned(
          right: -44,
          top: -54,
          width: 190,
          height: 190,
          child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: .12),
          ))),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 18), child: Column(
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
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _balanceBtn(
                  context,
                  icon: Icons.swap_horiz,
                  label: '划转到余额',
                  solid: true,
                  brand: brand,
                  onTap: () => _openTransfer(context),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _balanceBtn(
                  context,
                  icon: Icons.account_balance,
                  label: '佣金提现',
                  solid: false,
                  brand: brand,
                  onTap: () => _openWithdraw(context, ref),
                ),
              ),
            ],
          ),
        ],
      )),
      ]),
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
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // 金额：XbFitText.rich 保证一行完整显示（够位原尺寸、超宽整体缩放，绝不省略号，框架）；
        // 货币符号小字（原型 .invbal-num .cur 17px / 数字 30px）。
        XbFitText.rich(
          TextSpan(
            children: [
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
            ],
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: 7),
          Text(
            sub,
            style: TextStyle(
              fontSize: 10.5,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
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
    required VoidCallback onTap,
  }) {
    final Color bg;
    final Color fg;
    BoxBorder? border;
    if (solid) {
      bg = Colors.white.withValues(alpha: 0.94);
      fg = brand;
    } else {
      bg = Colors.white.withValues(alpha: 0.14);
      fg = Colors.white;
      border = Border.all(
        color: Colors.white.withValues(alpha: 0.5),
        width: 1.5,
      );
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
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: fg,
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

  void _openTransfer(BuildContext context) {
    xbShowDialog<void>(
      context: context,
      brandColor: xbBrandColor(),
      builder: (_) => _TransferDialog(info: info),
    );
  }

  void _openWithdraw(BuildContext context, WidgetRef ref) {
    if (ref.read(authStateProvider) != AuthState.authenticated) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (_withdrawDialogs[navigator]?.isActive ?? false) return;
    final owner = ref.read(xboardServiceProvider);
    final revision = ref.read(authStateProvider.notifier).sessionRevision;
    final route = xbDialogRoute<void>(
      context: context,
      barrierDismissible: false,
      brandColor: xbBrandColor(),
      builder: (_) => WithdrawCommissionDialog(owner: owner, revision: revision),
    );
    _withdrawDialogs[navigator] = route;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (identical(_withdrawDialogs[navigator], route)) {
          _withdrawDialogs[navigator] = null;
        }
      }),
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
      _stat(
        context,
        Icons.group,
        '已注册用户',
        '${info.registeredCount}',
        unit: '人',
      ),
      _stat(context, Icons.hourglass_top, '确认中佣金', xbYuan(info.pendingYuan)),
      _stat(context, Icons.savings, '累计获得佣金', xbYuan(info.totalYuan)),
      _stat(
        context,
        Icons.percent,
        '返佣比例',
        '${info.commissionRate}',
        unit: '%',
      ),
    ];
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: cells[0]),
            const SizedBox(width: 10),
            Expanded(child: cells[1]),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: cells[2]),
            const SizedBox(width: 10),
            Expanded(child: cells[3]),
          ],
        ),
      ],
    );
  }

  Widget _stat(
    BuildContext context,
    IconData icon,
    String label,
    String num, {
    String? unit,
  }) {
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
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.onv),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text.rich(
            TextSpan(
              children: [
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
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: t.onv,
                    ),
                  ),
              ],
            ),
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
    return XbCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.confirmation_number_outlined,
                    size: 16,
                    color: brand,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '我的邀请码',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: t.onv,
                    ),
                  ),
                  const Spacer(),
                  if (hasCode)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: XbTokens.ok.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 12,
                            color: XbTokens.ok,
                          ),
                          SizedBox(width: 3),
                          Text(
                            '已生效',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: XbTokens.ok,
                            ),
                          ),
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
                      brand.withValues(alpha: 0.16),
                      t.line,
                    ),
                  ),
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
                          borderRadius: BorderRadius.circular(12),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 11),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lightbulb_outline,
                    size: 14,
                    color: XbTokens.warn,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '该邀请码可以无限次使用',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.6,
                        color: t.onv,
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

// ───────────────────────── 返佣流程 5 步 ─────────────────────────

class _FlowSection extends StatelessWidget {
  const _FlowSection({required this.rate});
  final int rate;

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
                    _step(
                      context,
                      _steps[i].$1,
                      _steps[i].$2,
                      last: i == _steps.length - 1,
                    ),
                    if (i != _steps.length - 1)
                      Expanded(
                        child: Container(
                          height: 2,
                          margin: const EdgeInsets.only(bottom: 22),
                          color: Color.alphaBlend(
                            brand.withValues(alpha: 0.18),
                            t.line,
                          ),
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
                      style: TextStyle(
                        color: t.on,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const TextSpan(text: '客户端、'),
                    TextSpan(
                      text: '注册',
                      style: TextStyle(
                        color: t.on,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const TextSpan(text: '时填写你的邀请码并成功'),
                    TextSpan(
                      text: '购买',
                      style: TextStyle(
                        color: t.on,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const TextSpan(text: '套餐后，你将获得订单金额 '),
                    TextSpan(
                      text: '$rate%',
                      style: TextStyle(color: brand, fontWeight: FontWeight.w700),
                    ),
                    const TextSpan(text: ' 的返佣。'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _step(
    BuildContext context,
    IconData icon,
    String label, {
    required bool last,
  }) {
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
            color: last ? null : Color.alphaBlend(brand.withValues(alpha: 0.09), t.sfc),
            gradient: last ? LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [brand == const Color(0xffd92e1a)
                  ? const Color(0xffff5a44) : Color.lerp(brand, Colors.white, .16)!, brand],
            ) : null,
            boxShadow: last ? [BoxShadow(
              color: brand.withValues(alpha: .5), blurRadius: 14,
              spreadRadius: -6, offset: const Offset(0, 6),
            )] : null,
            border: last
                ? null
                : Border.all(
                    color: Color.alphaBlend(
                      brand.withValues(alpha: 0.22),
                      t.line,
                    ),
                    width: 1.5,
                  ),
          ),
          child: Icon(icon, size: 20, color: last ? Colors.white : brand),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: t.on,
          ),
        ),
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
    text: widget.info.commissionBalanceYuan.toStringAsFixed(2),
  );
  bool _submitting = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final cents = parseYuanCents(_amount.text);
    if (cents == null || parseYuanCents((cents / 100).toString()) != cents) {
      xbToast(context, '请输入有效的划转金额，最多两位小数');
      return;
    }
    final yuan = cents / 100;
    if (yuan > widget.info.commissionBalanceYuan) {
      xbToast(context, '划转金额不能超过佣金余额');
      return;
    }
    setState(() => _submitting = true);
    final result = await ref
        .read(xboardServiceProvider)
        .transferCommissionToBalance(yuan);
    if (!mounted) return;
    switch (result) {
      case XbSuccess(data: true):
        ref.invalidate(inviteInfoProvider);
        Navigator.of(context).pop();
        xbToast(context, '划转成功，已转入账户余额');
      case XbSuccess():
        setState(() => _submitting = false);
        xbToast(context, '操作结果尚未确认，请先核对余额和记录。如问题持续，请向客服反馈此问题。');
      case XbFailure(:final error):
        if (error is XbUnconfirmed) {
          ref.invalidate(inviteInfoProvider);
          ref.invalidate(commissionRecordsProvider);
        }
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
      scrollable: true,
      insetPadding: MediaQuery.sizeOf(context).width < 360
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10) : null,
      title: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [Text('划转到账户余额', textAlign: TextAlign.center)],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '佣金余额划转到账户余额后，可在购买 / 续费套餐时直接抵扣。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.5, color: t.onv),
          ),
          const SizedBox(height: 16),
          _TransferRow(
            from: widget.info.commissionBalanceYuan,
            to: widget.info.accountBalanceYuan,
          ),
          const SizedBox(height: 12),
          // 字段名常驻；保留真实可编辑的预填金额与「全部」操作。
          _CompactFieldShell(
            child: Row(
              children: [
                Text('划转金额', style: TextStyle(fontSize: 13, color: t.onv)),
                const SizedBox(width: 6),
                Text('¥', style: TextStyle(fontSize: 14.5, color: t.onv)),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: TextStyle(fontSize: 14.5, color: t.on),
                    decoration: const InputDecoration(
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
                      filled: false,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 「全部」：一键填入全部佣金余额（原型 .xfer-all 品牌色链接）。
                GestureDetector(
                  onTap: () => _amount.text = widget.info.commissionBalanceYuan
                      .toStringAsFixed(2),
                  child: Text(
                    '全部',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: brand,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: [
        _DialogActions(
          confirmLabel: '确认划转',
          submitting: _submitting,
          onConfirm: _submit,
        ),
      ],
    );
  }
}

// 弹窗公共小部件。

/// 原型 `.field` 紧凑输入行外壳：最小 48dp，按字号增高。
/// 包裹 Dropdown / TextField，替代 Material 浮动标签输入框（后者更高，观感不符原型）。
class _CompactFieldShell extends StatelessWidget {
  const _CompactFieldShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
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
          Text(
            xbYuan(amount),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
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
                  borderRadius: BorderRadius.circular(XbTokens.rMd),
                ),
              ),
              child: const Text('取消'),
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: SizedBox(
            height: 46,
            child: XbGradientAction(
              onPressed: submitting ? null : onConfirm,
              child: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(confirmLabel),
            ),
          ),
        ),
      ],
    );
  }
}
