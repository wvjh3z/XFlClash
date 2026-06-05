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

  @override
  void initState() {
    super.initState();
    // 形态 A 专属：把默认全屏红屏换成有界友好错误卡（W1.4 / R1.7）。
    // 仅 formA 路径执行（form B 不进 shell，保留 FlClash 默认错误处理，"加而不改"）。
    XbErrorBoundary.install();
  }

  void _onTabSelected(int index) => setState(() => _tabIndex = index);

  @override
  Widget build(BuildContext context) {
    // body 用 IndexedStack 保活（切 Tab 不重建，R1.4）。
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _tabIndex,
          children: [
            // 每个 Tab body 外包 XbErrorBoundary（R1.7：单 Tab 崩不波及内核 / 其它 Tab）。
            XbErrorBoundary(
              label: '首页',
              child: HomeTab(
                onTapToNodes: () => _onTabSelected(1),
                onTapLogin: () => showLoginSheet(context),
              ),
            ),
            XbErrorBoundary(
              label: '节点',
              child: NodesTab(
                onTapRenew: () => _onTabSelected(2),
                onTapLogin: () => showLoginSheet(context),
              ),
            ),
            XbErrorBoundary(
              label: '我的',
              child: MineTab(onTapLogin: () => showLoginSheet(context)),
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
