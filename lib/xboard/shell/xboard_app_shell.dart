/// 形态 A 品牌导航外壳。
///
/// **职责**：formA flavor 下接管首屏（替换 `Application.home` 的 `HomePage`），提供
/// 自定义 Tab（首页 / 节点 / 商店 / 我的）+ 自定义底栏。VPN 内核（Manager 链）在
/// `MaterialApp.builder:` 内，不在 `home:`，故换 home 不受影响（R1，PoC 已证）。
///
/// **🔴 适配层铁律**：本文件及 `tabs/` 下子 widget **禁止**直接 import
/// `package:fl_clash/views/**` 或 FlClash internal provider —— 一切 FlClash 内部复用
/// 必须经 `lib/xboard/shell/adapters/`（W2）收口。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show AppUpdateModel;

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/auth_expiry_notice_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/app_version.dart';
import 'package:fl_clash/xboard/widgets/xb_center_toast.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';

import 'adapters/xb_layout_adapter.dart';
import 'sheets/login_sheet.dart';
import 'tabs/home/home_tab.dart';
import 'tabs/mine/mine_tab.dart';
import 'tabs/mine/xb_settings_page.dart';
import 'tabs/nodes/nodes_tab.dart';
import 'tabs/shop/shop_tab.dart';
import 'tabs/shop/xb_shop_navigation.dart';
import 'widgets/xb_bottom_bar.dart';
import 'widgets/xb_error_boundary.dart';
import 'widgets/xb_nav_rail.dart';

enum _ShellTab { home, nodes, shop, mine, settings }

/// 形态 A 导航外壳。
class XboardAppShell extends ConsumerStatefulWidget {
  const XboardAppShell({super.key});

  @override
  ConsumerState<XboardAppShell> createState() => _XboardAppShellState();
}

class _XboardAppShellState extends ConsumerState<XboardAppShell> {
  _ShellTab _tab = _ShellTab.home;
  _ShellTab _lastCommonTab = _ShellTab.home;
  final PageController _pager = PageController();
  final GlobalKey<NavigatorState> _contentNavKey = GlobalKey<NavigatorState>();
  // Keep the route, pager and tab state mounted as window chrome changes.
  final _tabView = ValueNotifier<(_ShellTab, XbShopIntent?, int)>(
    (_ShellTab.home, null, 0),
  );
  XbShopIntent? _shopIntent;
  bool _contentCanPop = false;

  /// Tab 切换横滑时长/曲线。
  static const _slideDur = Duration(milliseconds: 300);
  static const _slideCurve = Curves.easeOutCubic;

  /// 首页「当前线路」点击 → 节点页定位目标（分组 + 节点）+ 自增请求序号
  /// （序号自增让 NodesTab 即便目标相同也能再次触发定位）。
  String? _nodeTargetGroup;
  String? _nodeTargetNode;
  int _nodeTargetNonce = 0;

  /// 桌面设置保持懒加载。
  bool _desktopSettingsVisited = false;

  /// 本会话是否已自动弹过更新弹窗（一次会话只自动弹一次，避免反复打扰）。
  bool _updateDialogShown = false;

  /// 只消费有效会话过期通知；普通登出、登录失败或网络错误不会触发此导航。
  int _lastAuthExpiryNotice = 0;

  @override
  void initState() {
    super.initState();
    // 形态 A 专属：把默认全屏红屏换成有界友好错误卡（W1.4 / R1.7）。
    // 仅 formA 路径执行（form B 不进 shell，保留 FlClash 默认错误处理，"加而不改"）。
    XbErrorBoundary.install();
    // 启动即记录版本(排查"装的是不是新版";print 在 debug logcat 可见)。
    // ignore: avoid_print
    print('[XB-VERSION] ${myClientVersionLabel()}');
  }

  @override
  void dispose() {
    _pager.dispose();
    _tabView.dispose();
    super.dispose();
  }

  /// 底栏/导航栏点击 → 切换目标页。
  void _onTabSelected(int index) {
    final tab = _ShellTab.values[index];
    if (tab == _tab) {
      final nav = _contentNavKey.currentState;
      if (nav != null && nav.canPop()) {
        nav.popUntil((r) => r.isFirst);
      }
      return;
    }
    _goTo(tab);
  }

  /// 页面横滑落定（含手指滑动）→ 同步选中态。
  void _onPageChanged(int index) {
    final tab = _ShellTab.values[index];
    if (tab != _tab) _select(tab);
  }

  void _select(_ShellTab tab) {
    setState(() {
      _tab = tab;
      if (tab == _ShellTab.settings) {
        _desktopSettingsVisited = true;
      } else {
        _lastCommonTab = tab;
      }
      if (tab != _ShellTab.shop) _shopIntent = null;
    });
    _refreshTabView();
  }

  void _refreshTabView() {
    _tabView.value = (_tab, _shopIntent, _nodeTargetNonce);
  }

  void _goTo(_ShellTab tab, {bool closeSubpages = true}) {
    if (closeSubpages) _contentNavKey.currentState?.popUntil((r) => r.isFirst);
    final leavingSettings = _tab == _ShellTab.settings;
    _select(tab);
    if (!_pager.hasClients) return;
    final page = _pager.page;
    // Intermediate pages are not user selections and must not cancel an intent.
    if (leavingSettings ||
        !ref.read(xbIsMobileViewProvider) ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
        page == null ||
        (page - tab.index).abs() > 1) {
      _pager.jumpToPage(tab.index);
    } else {
      _pager.animateToPage(tab.index, duration: _slideDur, curve: _slideCurve);
    }
  }

  void _openShop(XbShopIntent intent) {
    _shopIntent = intent;
    _goTo(_ShellTab.shop);
  }

  void _consumeShopIntent(XbShopIntent intent) {
    if (!identical(_shopIntent, intent)) return;
    _shopIntent = null;
    _refreshTabView();
  }

  /// 首页点「当前线路」：记录定位目标 + 自增序号 → 横滑到节点 Tab。
  void _onTapToNodes(String? group, String? node) {
    setState(() {
      _nodeTargetGroup = group;
      _nodeTargetNode = node;
      _nodeTargetNonce++;
    });
    _goTo(_ShellTab.nodes);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(authExpiryNoticeProvider, (previous, next) {
      if (next > _lastAuthExpiryNotice) _returnToGuestMine(next);
    });

    // 检测到更新 → 在 Tab 主界面自动弹一次更新弹窗。
    // 监听 provider 变化（VPN 连上/onResume 后检测到）+ build 时补查（冷启动已检测到）。
    ref.listen<AppUpdateModel?>(availableUpdateProvider, (prev, next) {
      if (next != null) _maybeAutoShowUpdate(next);
    });
    final existing = ref.watch(availableUpdateProvider);
    if (existing != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeAutoShowUpdate(existing);
      });
    }

    // 形态 A 品牌主题（W3 接线漏项修复）：用 flavor brandColor 锁死强调色族（primary=品牌红），
    // 中性灰出底，让整个外壳呈现品牌视觉，而非 FlClash 顶层 M3 动态色。
    // 不套则 Tab 跟随 FlClash 主题 → 品牌红被冲淡。
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: _buildScaffold(context),
    );
  }

  /// 认证清理后收起受保护子页与弹窗，恢复「我的」游客入口。
  ///
  /// 清理和页面重建可能同帧发生，导航放到帧后；若期间新账号已经登录，旧通知
  /// 不再关闭新账号的页面或显示过期提示。通知计数使 rebuild 不会重复提示。
  void _returnToGuestMine(int notice) {
    _lastAuthExpiryNotice = notice;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          ref.read(authExpiryNoticeProvider) != notice ||
          ref.read(authStateProvider) != AuthState.unauthenticated) {
        return;
      }

      final shellRoute = ModalRoute.of(context);
      Navigator.of(context, rootNavigator: true).popUntil(
        (route) => shellRoute == null ? route.isFirst : route == shellRoute,
      );
      _goTo(_ShellTab.mine);
      XbCenterToast.show(
        context,
        '登录已过期，请重新登录',
        icon: Icons.lock_outline_rounded,
        tone: XbToastTone.warning,
      );
    });
  }

  /// 自动弹更新弹窗（页面控制 + 一次会话一次）。
  ///
  /// 条件：本会话未弹过 + shell 与内容根路由均未被覆盖。
  /// 支付/详情/登录 sheet 等盖在上面时 isCurrent==false → 不弹，等回到 Tab 再弹。
  void _maybeAutoShowUpdate(AppUpdateModel info) {
    if (_updateDialogShown || _contentCanPop) return;
    // shell 不在栈顶（有子页/sheet 覆盖）→ 不弹。
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _updateDialogShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 再次确认在栈顶（post-frame 期间可能 push 了子页）。
      final r = ModalRoute.of(context);
      if (_contentCanPop || (r != null && !r.isCurrent)) {
        _updateDialogShown = false; // 复位，等下次回到 Tab 再弹
        return;
      }
      // The manifest may be withdrawn/replaced between scheduling and display.
      // Do not consume this shell's prompt allowance for a cancelled notice.
      final current = ref.read(availableUpdateProvider);
      if (current == null) {
        _updateDialogShown = false;
        return;
      }
      showXbUpdateDialog(context, current);
    });
  }

  List<Widget> _tabBodies(
    _ShellTab tab,
    XbShopIntent? intent, {
    required bool mobile,
  }) {
    return [
      XbErrorBoundary(
        label: '首页',
        child: HomeTab(
          onTapToNodes: _onTapToNodes,
          onTapLogin: () => showLoginSheet(context),
        ),
      ),
      XbErrorBoundary(
        label: '节点',
        child: NodesTab(
          onTapLogin: () => showLoginSheet(context),
          targetGroup: _nodeTargetGroup,
          targetNode: _nodeTargetNode,
          targetNonce: _nodeTargetNonce,
        ),
      ),
      XbErrorBoundary(
        label: '商店',
        child: ShopTab(
          active: tab == _ShellTab.shop,
          mobile: mobile,
          intent: intent,
          onIntentHandled: _consumeShopIntent,
          onTapLogin: () => showLoginSheet(context),
        ),
      ),
      XbErrorBoundary(
        label: '我的',
        child: MineTab(
          active: tab == _ShellTab.mine,
          onTapLogin: () => showLoginSheet(context),
        ),
      ),
      if (!mobile || tab == _ShellTab.settings)
        _desktopSettingsVisited
            ? const XbErrorBoundary(
                label: '设置',
                child: XbSettingsPage(embedded: true),
              )
            : const SizedBox.shrink(),
    ];
  }

  Widget _buildScaffold(BuildContext context) {
    final mobile = ref.watch(xbIsMobileViewProvider);
    final visibleTab = mobile && _tab == _ShellTab.settings
        ? _lastCommonTab
        : _tab;
    if (visibleTab != _tab) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _tab == _ShellTab.settings &&
            ref.read(xbIsMobileViewProvider)) {
          _goTo(visibleTab, closeSubpages: false);
        }
      });
    }
    return Scaffold(
      body: SafeArea(
        bottom: !mobile || _contentCanPop,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!mobile)
              XbNavRail(
                currentIndex: visibleTab.index,
                onTap: _onTabSelected,
                onTapAccount: () => _goTo(_ShellTab.mine),
              ),
            Expanded(
              key: const ValueKey('xb-shell-content'),
              child: NotificationListener<NavigationNotification>(
                onNotification: (_) {
                  final canPop = _contentNavKey.currentState?.canPop() ?? false;
                  if (canPop != _contentCanPop) {
                    setState(() => _contentCanPop = canPop);
                  }
                  return false;
                },
                child: NavigatorPopHandler<Object?>(
                  onPopWithResult: (result) {
                    final nav = _contentNavKey.currentState;
                    if (nav != null && nav.canPop()) nav.maybePop(result);
                  },
                  child: Navigator(
                    key: _contentNavKey,
                    onGenerateRoute: (_) => PageRouteBuilder<void>(
                      transitionDuration: Duration.zero,
                      reverseTransitionDuration: Duration.zero,
                      pageBuilder: (_, _, _) => _buildTabRoute(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: mobile && !_contentCanPop
          ? XbBottomBar(currentIndex: visibleTab.index, onTap: _onTabSelected)
          : null,
    );
  }

  Widget _buildTabRoute() => Material(
    type: MaterialType.transparency,
    child: XbShopNavigation(
      onOpen: _openShop,
      child: Consumer(
        builder: (context, ref, _) {
          final mobile = ref.watch(xbIsMobileViewProvider);
          return ValueListenableBuilder<(_ShellTab, XbShopIntent?, int)>(
            valueListenable: _tabView,
            builder: (context, selection, _) {
              final (tab, intent, _) = selection;
              return Stack(
                fit: StackFit.expand,
                children: [
                  PageView(
                    controller: _pager,
                    onPageChanged: _onPageChanged,
                    physics: mobile && tab != _ShellTab.settings
                        ? null
                        : const NeverScrollableScrollPhysics(),
                    children: [
                      for (final (index, body) in _tabBodies(
                        tab,
                        intent,
                        mobile: mobile,
                      ).indexed)
                        _KeepAliveTab(
                          child: ExcludeFocus(
                            excluding: index != tab.index,
                            child: TickerMode(
                              enabled: index == tab.index,
                              child: body,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (tab != _ShellTab.settings)
                    const Positioned(
                      right: 16,
                      bottom: 12,
                      child: AndroidResumeChat(),
                    ),
                ],
              );
            },
          );
        },
      ),
    ),
  );
}

/// 保留已访问 Tab 的滚动位置和本地状态。
class _KeepAliveTab extends StatefulWidget {
  const _KeepAliveTab({required this.child});

  final Widget child;

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求调用。
    return widget.child;
  }
}
