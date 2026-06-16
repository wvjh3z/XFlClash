/// 形态 A 桌面左侧导航栏（spec `xboard-form-a-ui-revamp` / C-分支桌面外壳）。
///
/// 桌面（宽窗口）专用：替代移动端底栏 [XbBottomBar]，提供 4 项纵向导航（首页 / 节点 / 我的 /
/// 设置）+ 底部账户身份芯片 + 版本号。win / mac / linux 通用。
///
/// **框架思维**：
/// - 导航项复用 [XbBottomBar.defaultItems]（单一数据源，移动/桌面同一套图标语义）+ 追加「设置」。
/// - 视觉全走 `Theme.of(context).colorScheme`（深浅色 / 品牌强调色自动随 `XbBrandTheme`）。
/// - 选中态、点按用 Material `InkWell` + `AnimatedContainer`，不手搓像素。
/// - 账户芯片消费 `userProfileProvider` / `authStateProvider`（◇ 复用形态 B 自有 provider）。
///
/// **适配层铁律**：纯 UI + xboard 自有 provider，不 import `lib/views/**` / FlClash internal provider。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/util/app_version.dart';
import 'package:fl_clash/xboard/util/format.dart';

import 'xb_bottom_bar.dart' show XbBottomBar, XbBottomBarItem;

/// 桌面左侧导航栏。
class XbNavRail extends StatelessWidget {
  const XbNavRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.onTapAccount,
    this.width = 208,
  });

  /// 当前选中 Tab index（0 首页 / 1 节点 / 2 我的 / 3 设置）。
  final int currentIndex;

  /// 导航项点击（传目标 index）。
  final ValueChanged<int> onTap;

  /// 底部账户芯片点击（→ 跳「我的」/ 登录）。
  final VoidCallback onTapAccount;

  /// 栏宽（默认 208；原型 .side 为 200，留 8px 余量避免账户芯片到期行在长文案下溢出）。
  final double width;

  /// 导航项 = 复用移动端底栏三项（单一数据源）+ 追加「设置」（桌面独立 Tab）。
  static const List<XbBottomBarItem> _items = [
    ...XbBottomBar.defaultItems,
    XbBottomBarItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: '设置',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: scheme.outlineVariant)),
        ),
        // 矮屏（如手机横屏 393 高）保护：内容够高 → 账户卡靠 Spacer 贴底；
        // 不够高 → 整列可滚动，避免竖向 overflow（框架式「footer 贴底 + 矮屏滚动」）。
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _RailBrand(),
                    const SizedBox(height: 16),
                    // 导航项组。
                    for (var i = 0; i < _items.length; i++)
                      Padding(
                        padding: EdgeInsets.only(
                            bottom: i == _items.length - 1 ? 0 : 8),
                        child: _RailItem(
                          item: _items[i],
                          selected: i == currentIndex,
                          onTap: () => onTap(i),
                        ),
                      ),
                    const Spacer(),
                    // 底部账户身份芯片。
                    _RailAccountChip(onTap: onTapAccount),
                    const SizedBox(height: 11),
                    const _RailVersion(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部品牌区（logo + 名称）。
class _RailBrand extends StatelessWidget {
  const _RailBrand();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                      Colors.white.withValues(alpha: 0.22), scheme.primary),
                  scheme.primary,
                ],
              ),
            ),
            child: const Icon(Icons.shield, color: Colors.white, size: 23),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'MyClient',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个导航项：图标靠左、文字居中（Clash Verge 风格）；选中=品牌色淡胶囊 + 品牌字。
class _RailItem extends StatelessWidget {
  const _RailItem({
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
    final fg = selected ? scheme.primary : scheme.onSurface;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 52,
          // Stack：图标绝对靠左 + 文字整宽居中（图标不挤压文字重心）。
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 14,
                top: 0,
                bottom: 0,
                child: Icon(
                  selected ? item.selectedIcon : item.icon,
                  size: 26,
                  color: fg,
                ),
              ),
              Text(
                item.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部账户身份芯片：已登录显示头像 + 套餐名 + 邮箱 + 流量条 + 到期；游客显示「未登录」。
class _RailAccountChip extends ConsumerWidget {
  const _RailAccountChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isGuest =
        ref.watch(authStateProvider) != AuthState.authenticated;

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(11, 11, 11, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: isGuest
              ? const _AccountChipBody(
                  title: '未登录',
                  subtitle: '点击登录 / 注册',
                )
              : ref.watch(userProfileProvider).when(
                    loading: () => const _AccountChipBody(
                      title: '加载中…',
                      subtitle: '正在同步账号信息',
                    ),
                    error: (_, _) => const _AccountChipBody(
                      title: '账号信息',
                      subtitle: '点击重新加载',
                    ),
                    data: (sub) => _AccountChipBody(
                      title: sub.planName ?? '未订阅套餐',
                      subtitle: sub.email,
                      sub: sub,
                    ),
                  ),
        ),
      ),
    );
  }
}

/// 账户芯片主体（头像行 + 可选流量条/到期行）。抽出供游客/加载/数据三态共用。
class _AccountChipBody extends StatelessWidget {
  const _AccountChipBody({
    required this.title,
    required this.subtitle,
    this.sub,
  });

  final String title;
  final String subtitle;

  /// 非空 → 渲染流量条 + 到期行（已登录数据态）。
  final XbDomainSubscription? sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sub = this.sub;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
        if (sub != null) ...[
          const SizedBox(height: 12),
          _ChipTraffic(sub: sub),
          if (sub.expiredAt != null) ...[
            const SizedBox(height: 10),
            _ChipExpiry(expiredAt: sub.expiredAt!),
          ],
        ],
      ],
    );
  }
}

/// 芯片内流量条（已用 X% + 进度条）。
class _ChipTraffic extends StatelessWidget {
  const _ChipTraffic({required this.sub});

  final XbDomainSubscription sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usedPct = sub.totalBytes == 0
        ? 0.0
        : (sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('流量',
                style: TextStyle(
                    fontSize: 10.5, color: scheme.onSurfaceVariant)),
            Text(
              '已用 ${(usedPct * 100).round()}%',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: usedPct,
            minHeight: 6,
            backgroundColor: scheme.onSurfaceVariant.withValues(alpha: 0.18),
            valueColor: AlwaysStoppedAnimation(scheme.primary),
          ),
        ),
      ],
    );
  }
}

/// 芯片内到期行（左「剩余…」+ 右日期）。
class _ChipExpiry extends StatelessWidget {
  const _ChipExpiry({required this.expiredAt});

  final DateTime expiredAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expired = !expiredAt.isAfter(DateTime.now());
    final left = expired ? '已过期' : xbRemainLabel(expiredAt);
    final date =
        '${expiredAt.month.toString().padLeft(2, '0')}-${expiredAt.day.toString().padLeft(2, '0')} 到期';
    return Row(
      children: [
        Icon(Icons.schedule,
            size: 13,
            color: expired ? scheme.error : scheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(
          left,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: expired ? scheme.error : scheme.onSurface,
          ),
        ),
        const Spacer(),
        Text(
          date,
          style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 底部版本号：MyClient 产品版本（上）+ 内核版本（下），均小字居中。
class _RailVersion extends StatelessWidget {
  const _RailVersion();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          myClientVersionLabel(),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '内核 FlClash 0.8.93',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
