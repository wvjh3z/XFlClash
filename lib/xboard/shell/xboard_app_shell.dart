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

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/util/app_version.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbBrandTheme;

import 'sheets/login_sheet.dart';
import 'tabs/home/home_tab.dart';
import 'tabs/mine/mine_tab.dart';
import 'tabs/nodes/nodes_tab.dart';
import 'widgets/xb_bottom_bar.dart';
import 'widgets/xb_error_boundary.dart';

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

  /// Tab 切换横滑时长/曲线。
  static const _slideDur = Duration(milliseconds: 300);
  static const _slideCurve = Curves.easeOutCubic;

  /// 首页「当前线路」点击 → 节点页定位目标（分组 + 节点）+ 自增请求序号
  /// （序号自增让 NodesTab 即便目标相同也能再次触发定位）。
  String? _nodeTargetGroup;
  String? _nodeTargetNode;
  int _nodeTargetNonce = 0;

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
    super.dispose();
  }

  /// 底栏点击 → 横滑到目标页。
  void _onTabSelected(int index) {
    if (index == _tabIndex) return;
    _slideTo(index);
  }

  /// 页面横滑落定（含手指滑动）→ 同步选中态。
  void _onPageChanged(int index) {
    if (index != _tabIndex) setState(() => _tabIndex = index);
  }

  void _slideTo(int index) {
    setState(() => _tabIndex = index);
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
    _slideTo(1);
  }

  @override
  Widget build(BuildContext context) {
    // 形态 A 品牌主题（W3 接线漏项修复）：用 flavor brandColor 锁死强调色族（primary=品牌红），
    // 中性灰出底，让整个外壳呈现品牌视觉，而非 FlClash 顶层 M3 动态色。
    // 不套则三 Tab 跟随 FlClash 主题 → 品牌红被冲淡成灰/暗粉（与原型差异的根因）。
    return XbBrandTheme(
      brandColor: Color(XboardConfig.current.brandColor),
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    // body 用 PageView 横向滑动切换（点底栏 animateToPage / 手指左右滑）。
    // 每个 Tab 用 _KeepAliveTab 保活（切走不 dispose，状态/滚动位置不丢，等价原 IndexedStack）。
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: PageView(
          controller: _pager,
          onPageChanged: _onPageChanged,
          children: [
            // 每个 Tab body 外包 XbErrorBoundary（R1.7：单 Tab 崩不波及内核 / 其它 Tab）。
            _KeepAliveTab(
              child: XbErrorBoundary(
                label: '首页',
                child: HomeTab(
                  onTapToNodes: _onTapToNodes,
                  onTapLogin: () => showLoginSheet(context),
                ),
              ),
            ),
            _KeepAliveTab(
              child: XbErrorBoundary(
                label: '节点',
                child: NodesTab(
                  onTapRenew: () => _onTabSelected(2),
                  onTapLogin: () => showLoginSheet(context),
                  targetGroup: _nodeTargetGroup,
                  targetNode: _nodeTargetNode,
                  targetNonce: _nodeTargetNonce,
                ),
              ),
            ),
            _KeepAliveTab(
              child: XbErrorBoundary(
                label: '我的',
                child: MineTab(
                  active: _tabIndex == 2,
                  onTapLogin: () => showLoginSheet(context),
                ),
              ),
            ),
          ],
        ),
      ),
      // W1.3 自定义底栏 XbBottomBar。
      bottomNavigationBar: XbBottomBar(
        currentIndex: _tabIndex,
        onTap: _onTabSelected,
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
