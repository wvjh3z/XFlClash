/// 形态 A 自定义三 Tab 外壳（spec `xboard-form-a-ui-revamp` / design P1 接缝点 #9）。
///
/// **职责**：formA flavor 下接管首屏（替换 `Application.home` 的 `HomePage`），提供
/// 自定义三 Tab（首页 / 节点 / 我的）+ 自定义底栏。VPN 内核（Manager 链）在
/// `MaterialApp.builder:` 内，不在 `home:`，故换 home 不受影响（R1，PoC 已证）。
///
/// **🔴 适配层铁律**：本文件及 `tabs/` 下子 widget **禁止**直接 import
/// `package:fl_clash/views/**` 或 FlClash internal provider —— 一切 FlClash 内部复用
/// 必须经 `lib/xboard/shell/adapters/`（W2）收口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show AppUpdateModel;

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/util/app_version.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';

import 'adapters/xb_layout_adapter.dart';
import 'sheets/login_sheet.dart';
import 'tabs/home/home_tab.dart';
import 'tabs/mine/mine_tab.dart';
import 'tabs/mine/xb_settings_page.dart';
import 'tabs/nodes/nodes_tab.dart';
import 'widgets/xb_bottom_bar.dart';
import 'widgets/xb_error_boundary.dart';
import 'widgets/xb_nav_rail.dart';

/// 形态 A 三 Tab 外壳（首页 / 节点 / 我的）。
class XboardAppShell extends ConsumerStatefulWidget {
  const XboardAppShell({super.key});

  @override
  ConsumerState<XboardAppShell> createState() => _XboardAppShellState();
}

class _XboardAppShellState extends ConsumerState<XboardAppShell> {
  /// 当前选中 Tab index（局部 state，默认 0=首页）。
  ///
  /// **不依赖** FlClash `currentPageLabelProvider` / `navigationStateProvider`
  /// （接口约定，避免与 FlClash 导航状态机耦合）。
  int _tabIndex = 0;

  /// 三 Tab 横向滑动控制（点底栏/线路卡 → 页面横滑过去，带方向感）。
  /// 各 Tab 用 keep-alive 保活（切走不重建，状态/滚动位置不丢）。
  final PageController _pager = PageController();

  /// 桌面内容区嵌套 Navigator（C-分支）：子页（设置/关于/订单/购买/支付/重置）push 进此
  /// Navigator → 只覆盖右侧内容区，左侧 NavRail 始终保留（原型屏4-8 桌面交互）。
  /// Tab 内 `xbPush` 用 `Navigator.of(context)` 会自动解析到此 Navigator；弹窗/sheet 走
  /// `showDialog`(useRootNavigator) 仍覆盖全屏。移动端无此 Navigator（全屏跳转，符合移动直觉）。
  final GlobalKey<NavigatorState> _contentNavKey = GlobalKey<NavigatorState>();

  /// 驱动内容区 IndexedStack 当前 Tab 的通知器：NavRail 切 Tab 只更新它（重建 IndexedStack），
  /// 不重建整个 Navigator（避免丢失已 push 的子页栈/触发整树重建）。
  final ValueNotifier<int> _tabIndexVN = ValueNotifier<int>(0);

  /// Tab 切换横滑时长/曲线。
  static const _slideDur = Duration(milliseconds: 300);
  static const _slideCurve = Curves.easeOutCubic;

  /// 首页「当前线路」点击 → 节点页定位目标（分组 + 节点）+ 自增请求序号
  /// （序号自增让 NodesTab 即便目标相同也能再次触发定位）。
  String? _nodeTargetGroup;
  String? _nodeTargetNode;
  int _nodeTargetNonce = 0;

  /// 桌面「设置」Tab 是否已被访问过（懒加载守卫）：重的原生 ToolsView 仅在用户首次切到
  /// 设置 Tab 后才构建，之后随 IndexedStack 保活。避免冷启动即构建从未打开的设置页。
  bool _desktopSettingsVisited = false;

  /// 本会话是否已自动弹过更新弹窗（一次会话只自动弹一次，避免反复打扰）。
  bool _updateDialogShown = false;

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
    _tabIndexVN.dispose();
    super.dispose();
  }

  /// 底栏/导航栏点击 → 切换目标页。
  void _onTabSelected(int index) {
    // 桌面：点当前 Tab 且内容区有子页 → 弹回该 Tab 根（不切 Tab）。
    if (index == _tabIndex) {
      final nav = _contentNavKey.currentState;
      if (nav != null && nav.canPop()) {
        nav.popUntil((r) => r.isFirst);
      }
      return;
    }
    _goTo(index);
  }

  /// 页面横滑落定（含手指滑动）→ 同步选中态。
  void _onPageChanged(int index) {
    if (index != _tabIndex) {
      setState(() => _tabIndex = index);
      _tabIndexVN.value = index;
    }
  }

  /// 切换到目标 Tab（统一入口）。移动端有 PageController → 横滑；
  /// 桌面分支（嵌套 Navigator + IndexedStack）→ 先弹回内容区根，再切 index（驱动通知器）。
  void _goTo(int index) {
    // 桌面：切 Tab 前先把内容区子页栈弹回根（避免切到他 Tab 仍盖着旧子页）。
    _contentNavKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {
      _tabIndex = index;
      if (index == 3) _desktopSettingsVisited = true; // 桌面设置 Tab：首访即解锁懒加载。
    });
    _tabIndexVN.value = index; // 驱动内容区 IndexedStack 切换（桌面）。
    // 桌面 IndexedStack 分支：PageView 未构建（controller 无 client）→ 仅切 index 即可。
    if (!_pager.hasClients) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _pager.jumpToPage(index); // 减弱动态效果 → 瞬切。
    } else {
      _pager.animateToPage(index, duration: _slideDur, curve: _slideCurve);
    }
  }

  /// 首页点「当前线路」：记录定位目标 + 自增序号 → 横滑到节点 Tab。
  void _onTapToNodes(String? group, String? node) {
    setState(() {
      _nodeTargetGroup = group;
      _nodeTargetNode = node;
      _nodeTargetNonce++;
    });
    _goTo(1);
  }

  @override
  Widget build(BuildContext context) {
    // 检测到更新 → 在三 Tab 主界面自动弹一次更新弹窗（页面控制 + 一次会话一次）。
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
    // 不套则三 Tab 跟随 FlClash 主题 → 品牌红被冲淡成灰/暗粉（与原型差异的根因）。
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: _buildScaffold(context),
    );
  }

  /// 自动弹更新弹窗（页面控制 + 一次会话一次）。
  ///
  /// 条件：本会话未弹过 + shell 在栈顶（无子页/sheet 盖着，即用户在三 Tab 主界面）。
  /// 支付/详情/登录 sheet 等盖在上面时 isCurrent==false → 不弹，等回到 Tab 再弹。
  void _maybeAutoShowUpdate(AppUpdateModel info) {
    if (_updateDialogShown) return;
    // shell 不在栈顶（有子页/sheet 覆盖）→ 不弹。
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _updateDialogShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 再次确认在栈顶（post-frame 期间可能 push 了子页）。
      final r = ModalRoute.of(context);
      if (r != null && !r.isCurrent) {
        _updateDialogShown = false; // 复位，等下次回到 Tab 再弹
        return;
      }
      showXbUpdateDialog(context, info);
    });
  }

  /// 三个 Tab 子树（含 XbErrorBoundary，R1.7：单 Tab 崩不波及内核 / 其它 Tab）。
  ///
  /// 抽出供「移动端 PageView」与「桌面 IndexedStack」两种外壳复用（C-分支）。
  /// 不含 _KeepAliveTab：PageView 分支按需包保活；IndexedStack 天然全保活。
  List<Widget> _tabBodies(BuildContext context) {
    return [
      XbErrorBoundary(
        label: '首页',
        child: HomeTab(
          onTapToNodes: _onTapToNodes,
          onTapLogin: () => showLoginSheet(context),
          onTapRenew: () => _goTo(2),
        ),
      ),
      XbErrorBoundary(
        label: '节点',
        child: NodesTab(
          onTapRenew: () => _onTabSelected(2),
          onTapLogin: () => showLoginSheet(context),
          targetGroup: _nodeTargetGroup,
          targetNode: _nodeTargetNode,
          targetNonce: _nodeTargetNonce,
        ),
      ),
      XbErrorBoundary(
        label: '我的',
        child: MineTab(
          active: _tabIndex == 2,
          onTapLogin: () => showLoginSheet(context),
        ),
      ),
    ];
  }

  /// 外壳骨架：按响应式视图分流（C-分支）。
  /// - 窄窗口（移动 / 桌面小窗）→ PageView + 底栏。
  /// - 宽窗口（桌面）→ 左侧 NavRail + IndexedStack（win / mac / linux 通用）。
  Widget _buildScaffold(BuildContext context) {
    final isMobile = ref.watch(xbIsMobileViewProvider);
    return isMobile
        ? _buildMobileScaffold(context)
        : _buildDesktopScaffold(context);
  }

  /// 移动端外壳：body 用 PageView 横向滑动切换（点底栏 animateToPage / 手指左右滑）。
  /// 每个 Tab 用 _KeepAliveTab 保活（切走不 dispose，状态/滚动位置不丢，等价原 IndexedStack）。
  Widget _buildMobileScaffold(BuildContext context) {
    final bodies = _tabBodies(context);
    // 桌面缩窄回移动端时 _tabIndex 可能是 3（设置，移动端无该 Tab）→ 钳到 0..2。
    final mobileIndex = _tabIndex > 2 ? 0 : _tabIndex;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: PageView(
          controller: _pager,
          onPageChanged: _onPageChanged,
          children: [
            for (final body in bodies) _KeepAliveTab(child: body),
          ],
        ),
      ),
      // W1.3 自定义底栏 XbBottomBar。
      bottomNavigationBar: XbBottomBar(
        currentIndex: mobileIndex,
        onTap: _onTabSelected,
      ),
    );
  }

  /// 桌面外壳：左侧 NavRail（4 项 + 账户芯片 + 版本）+ 内容区嵌套 Navigator（C-分支）。
  /// 内容区根路由 = IndexedStack（三 Tab + 设置 ToolsView）；子页 push 进此 Navigator →
  /// 只覆盖内容区、NavRail 保留（原型屏4-8）。第 4 Tab「设置」= 内嵌原生 ToolsView（加而不改）。
  Widget _buildDesktopScaffold(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            XbNavRail(
              currentIndex: _tabIndex,
              onTap: _onTabSelected,
              onTapAccount: () => _goTo(2),
            ),
            Expanded(
              child: Navigator(
                key: _contentNavKey,
                onGenerateRoute: (_) => PageRouteBuilder(
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                  // 透明 → 透出下层 Scaffold 的中性底（XbBrandTheme 注入的 t.sf），
                  // 不显式取色（避免误用外层 FlClash 主题的 M3 品牌色调底致「泛红」）。
                  pageBuilder: (_, _, _) => Material(
                    type: MaterialType.transparency,
                    child: ValueListenableBuilder<int>(
                      valueListenable: _tabIndexVN,
                      builder: (context, idx, _) {
                        final bodies = _tabBodies(context);
                        // 懒加载：未访问过设置 Tab 时占位空盒；首访后构建并保活。
                        // 第 4 Tab「设置」直接复用 Xboard 自有设置页（XbSettingsPage 嵌入态）——
                        // 与「我的」Tab 设置入口同一份内容，不再内嵌原生 ToolsView（去重 + 规避
                        // 原生页在 build 期改 provider 致渲染崩溃黑屏；深层编辑屏仍经 adapter push）。
                        final settingsBody = _desktopSettingsVisited
                            ? const XbErrorBoundary(
                                label: '设置',
                                child: XbSettingsPage(embedded: true),
                              )
                            : const SizedBox.shrink();
                        return IndexedStack(
                          index: idx,
                          children: [...bodies, settingsBody],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// PageView 子页保活包装：让滑走的 Tab 不被 dispose（保留滚动位置 / State），
/// 等价原 IndexedStack 的保活语义。
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
