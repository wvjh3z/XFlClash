/// 形态 A 节点 Tab（spec `xboard-form-a-ui-revamp` / W4.1·W4.2 / R4.1-R4.7）。
///
/// 组装：刷新按钮（R4.5，重拉订阅）+ 自绘分组/节点行（[XbNodeGroup]，原型 `.node` 列表行）+
/// 空态引导续费（R4.6）+ 游客引导（R4.7）。
///
/// **加而不改**：不再复用 FlClash `ProxyGroupView`/`ProxyCard`（网格卡），改自绘列表行；
/// 内核数据（延迟/选中/选择/测速）经 [XbNodesAdapter] 收口（适配层铁律），不直接碰 `lib/views/**`。
library;

import 'dart:async';
import '../../../providers/subscription_sync_status.dart';
import '../../../providers/xboard_connectivity_provider.dart';
import '../../../providers/network_recovery_provider.dart';

import 'package:fl_clash/xboard/widgets/xb_emoji_text.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/navigation/plan_navigation.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/services/xboard_subscription_service.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_feedback.dart' show xbToast;
import 'package:fl_clash/xboard/widgets/xb_refresh_throttle_guard.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart' show XbTokens;
import 'package:prism_ui/prism_ui.dart' show AppRadius, AppTextStyle;
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart' show XbGradientAction;

import '../../../../ui/icons/icons.dart'
    show AppGlyphs, Glyph, GlyphIcon, GlyphPolyline, GlyphRole, GlyphVertex;
import '../../adapters/xb_nodes_adapter.dart';
import '../../adapters/xb_group_tabs.dart';
import '../../widgets/xb_content_header.dart';
import '../../widgets/xb_responsive.dart';
import '../../widgets/xb_tab_refresh_indicator.dart';
import 'xb_node_group.dart';
import 'xb_group_delay_action.dart';
import 'xb_node_capsule_action.dart';

/// 节点页 master-detail：可用宽 ≥ [XbBreakpoints.desktop] 才双栏（策略见 xb_responsive）。

/// 节点 Tab。
class NodesTab extends ConsumerStatefulWidget {
  const NodesTab({
    super.key,
    this.onTapRenew,
    this.onTapLogin,
    this.targetGroup,
    this.targetNode,
    this.targetNonce = 0,
  });

  /// 空态点击续费（可注入；默认请求所在外壳的商店）。
  final VoidCallback? onTapRenew;

  /// 游客点击登录（shell 注入）。
  final VoidCallback? onTapLogin;

  /// 从首页「当前线路」进入时的目标分组名（打开即切到该分组）。null = 不定向。
  final String? targetGroup;

  /// 目标节点名（在分组内滚动到该节点并尽量上下居中）。
  final String? targetNode;

  /// 定向请求序号（shell 每次点线路卡自增）：用于即便目标相同也能再次触发定位。
  final int targetNonce;

  @override
  ConsumerState<NodesTab> createState() => _NodesTabState();
}

class _NodesTabState extends ConsumerState<NodesTab>
    with XbRefreshThrottleGuard {
  /// 正在刷新节点（重拉订阅 + 解密 + 写入新 profile）。期间刷新按钮禁用并显示忙态；
  /// 旧节点保留显示（不清空），写入成功后 profile 重载自动覆盖。
  bool _refreshing = false;
  int _refreshGeneration = 0;
  int _sampledEpoch = 0;
  Object? _readOwner;
  Timer? _waitTimer;
  Completer<void>? _uiWait;

  void _releaseReadWait() {
    _waitTimer?.cancel();
    _waitTimer = null;
    final wait = _uiWait;
    _uiWait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  @override
  void dispose() {
    _readOwner = null;
    _releaseReadWait();
    super.dispose();
  }

  /// 当前选中的分组名（顶部 tab）。null = 用首个可见分组。
  String? _selectedGroup;
  bool? _lastGlobalMode;
  PageStorageBucket _groupScrollStorage = PageStorageBucket();

  /// 待定位到的节点名（传给 XbNodeGroup 滚动居中）；消费后清空（只定位一次）。
  String? _pendingScrollNode;

  /// 已处理的定向请求序号（避免重复定位）。
  int _handledNonce = 0;

  @override
  void initState() {
    super.initState();
    _applyTarget();
  }

  @override
  void didUpdateWidget(covariant NodesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetNonce != _handledNonce) {
      setState(_applyTarget);
    }
  }

  /// 应用首页传入的定向：切到目标分组 + 记录待滚动节点。
  void _applyTarget() {
    _handledNonce = widget.targetNonce;
    if (widget.targetGroup != null) {
      _selectedGroup = widget.targetGroup;
      _pendingScrollNode = widget.targetNode;
    }
  }

  /// 刷新 = 重拉订阅并解密写入新节点（2-A）。await sync(force) 拿状态码：
  /// ok=写入新 profile；subscriptionExpired/noSubscription/trafficExhausted/authExpired=
  /// 加密订阅端点的服务端真相（插件 40304/40305/40307/4030x）。据此出文案并发布共享结果，
  /// A successful sync only rechecks account data when a local denial still blocks the list.
  Future<void> _refreshNodes() {
    if (_readOwner != null) {
      if (!_refreshing) xbToast(context, '线路同步仍在后台进行，请稍候');
      return Future.value();
    }
    final owner = _readOwner = Object();
    final wait = _uiWait = Completer<void>();
    _waitTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted || !identical(owner, _readOwner)) return;
      _releaseReadWait();
      setState(() => _refreshing = false);
      xbToast(context, '网络响应较慢，线路将在后台继续同步');
    });
    unawaited(_runRefreshNodes().whenComplete(() {
      if (identical(owner, _readOwner)) {
        _readOwner = null;
        _releaseReadWait();
      }
    }));
    return wait.future;
  }

  Future<void> _runRefreshNodes() async {
    if (ref.read(authStateProvider) != AuthState.authenticated) return;
    if (_refreshing) return;
    if (ref.read(interfaceUnavailableProvider)) {
      xbToast(context, '未检测到网络连接，请连接网络后重试');
      return;
    }
    if (throttled) {
      xbToast(context, '节点刚刷新过，请稍后再试');
      return;
    }
    final auth = ref.read(authStateProvider.notifier);
    final revision = auth.sessionRevision;
    final ticket = ++_refreshGeneration;
    bool ownsPage() => mounted && ticket == _refreshGeneration &&
        identical(ref.read(authStateProvider.notifier), auth) && auth.sessionRevision == revision &&
        ref.read(authStateProvider) == AuthState.authenticated;
    setState(() => _refreshing = true);
    var outcome = XbSyncOutcome.failed;
    final status = ref.read(subscriptionSyncStatusProvider.notifier);
    final before = status.completion;
    XboardSubscriptionService? sync;
    try {
      final currentSync = ref.read(subscriptionServiceProvider);
      sync = currentSync;
      outcome = await currentSync.sync(force: true);
    } catch (_) {
      // 永不抛（Property 1）；当作失败处理。
    }
    try {
      if (!ownsPage()) return;
      if (sync != null && !identical(sync, ref.read(subscriptionServiceProvider))) return;
      final latest = ref.read(subscriptionSyncStatusProvider);
      if (outcome != XbSyncOutcome.ok || status.completion == before || latest?.outcome == XbSyncOutcome.ok) {
        status.publish(outcome, revision);
      }
      if (outcome == XbSyncOutcome.ok && ref.read(subscriptionSyncStatusProvider)?.outcome == XbSyncOutcome.ok) {
        final hold = ref.read(nodeProfileHoldProvider.notifier);
        final sub = hold.forRevision(revision) ?? ref.read(userProfileProvider).asData?.value;
        if (sub != null && (_isExpired(sub) || _isExhausted(sub))) {
          hold.hold(sub);
          final accountService = ref.read(xboardServiceProvider);
          bool ownsRecheck() => ownsPage() &&
              identical(sync, ref.read(subscriptionServiceProvider)) &&
              identical(accountService, ref.read(xboardServiceProvider));
          try {
            ref.invalidate(userProfileProvider);
            await ref.read(userProfileProvider.future);
            if (!ownsRecheck()) return;
          } catch (_) {
            if (!ownsRecheck()) return;
            if (mounted && ref.read(subscriptionSyncStatusProvider)?.outcome == XbSyncOutcome.ok) {
              xbToast(context, '账号资料未能更新，请稍后重试');
            }
            return;
          }
        }
      }
      if (!ownsPage() || (sync != null && !identical(sync, ref.read(subscriptionServiceProvider)))) return;
      if (outcome == XbSyncOutcome.ok) startThrottle();
    } finally {
      if (mounted && ticket == _refreshGeneration) setState(() => _refreshing = false);
    }
    if (mounted && outcome != XbSyncOutcome.ok) {
      final msg = switch (outcome) {
        XbSyncOutcome.subscriptionExpired => '套餐已过期，请前往续费 / 购买',
        XbSyncOutcome.trafficExhausted => '本周期流量已用尽，请重置流量或更改套餐',
        XbSyncOutcome.noSubscription => '当前套餐无可用线路，请购买套餐',
        XbSyncOutcome.authExpired => '登录已过期，请重新登录',
        _ => '刷新失败，请稍后重试',
      };
      xbToast(context, msg);
    }
  }

  /// 套餐是否已过期（expiredAt 非空且不在未来）。expiredAt==null = 长期有效（不算过期）。
  bool _isExpired(XbDomainSubscription sub) =>
      sub.expiredAt != null && !sub.expiredAt!.isAfter(DateTime.now());
  bool _isExhausted(XbDomainSubscription sub) =>
      !sub.hasNoPlan && sub.totalBytes > 0 && sub.usedBytes >= sub.totalBytes;

  /// 决定是否渲染空态及哪一种（清空节点）。综合两路信号，取「更差」者，优先级 过期 > 无套餐 > 用尽：
  /// ① 当前会话共享同步结果：加密订阅端点的服务端真相（手动或后台）；
  /// ② 本地 [sub]（userProfile）：冷启动尚无刷新结果、或「我的」页刚刷新过账号信息时的兜底。
  /// 返回 null = 不强制空态（交给 nodesView：有节点则展示，无则走通用空态）。
  Widget? _resolveEmptyBody(XbDomainSubscription? sub) {
    final status = ref.watch(subscriptionSyncStatusProvider);
    final o = status?.revision == ref.read(authStateProvider.notifier).sessionRevision
        ? status?.outcome : null;
    final localExpired = sub != null && _isExpired(sub);
    // 用尽判定带 totalBytes>0 守卫：避免「不限量套餐 totalBytes==0」被误判为用尽。
    final localExhausted = sub != null && _isExhausted(sub);

    // 过期（最高优先）：服务端 40304 或本地过期。
    if (o == XbSyncOutcome.authExpired) {
      return const XbEmptyState(icon: Icons.lock_outline, title: '登录已过期', description: '请重新登录后同步线路。');
    }
    if (o == XbSyncOutcome.subscriptionExpired || o == XbSyncOutcome.noSubscription) {
      return _EmptyNodes(onTapRenew: _openShop);
    }
    // 流量用尽：服务端 40307 或本地用尽。
    if (o == XbSyncOutcome.trafficExhausted) return _exhaustedBody();
    if (localExpired) return _EmptyNodes(onTapRenew: _openShop);
    if (localExhausted) {
      return _exhaustedBody();
    }
    return null;
  }

  void _openShop() =>
      (widget.onTapRenew ?? () => openCurrentPlanRenew(context, ref))();

  /// 流量用尽空态体；重置包点击时读取本账户套餐。
  Widget _exhaustedBody() {
    return _ExhaustedNodes(
      onBuyResetPack: () => openCurrentTrafficReset(context, ref),
      onBuyPlan: _openShop,
    );
  }

  /// 空态外壳：顶部标题栏（含刷新节点）+ 居中空态体。
  /// 无可用线路 / 套餐过期 / 流量用尽三种空态共用（结构一致，仅 body 不同）。
  Widget _emptyShell(Widget body) {
    return Column(
      children: [
        _NodesHeader(
          onRefresh: _refreshNodes,
          refreshing: _refreshing,
          cooldownSec: cooldownSeconds,
        ),
        Expanded(
          child: XbTabRefreshIndicator(
            onRefresh: _refreshNodes,
            // 空态自身已有滚动容器：只调整其物理规则，不再嵌套另一层滚动。
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                physics: const AlwaysScrollableScrollPhysics(),
              ),
              child: body,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authStateProvider, (previous, next) {
      if (previous != next) {
        setState(() {
          _refreshGeneration++;
          _readOwner = null;
          _releaseReadWait();
          _refreshing = false;
          _groupScrollStorage = PageStorageBucket();
          ref.read(subscriptionSyncStatusProvider.notifier).clear();
        });
        resetThrottle();
      }
    });
    final isGuest = ref.watch(authStateProvider) != AuthState.authenticated;
    if (isGuest) {
      final android = Theme.of(context).platform == TargetPlatform.android;
      return LayoutBuilder(
        builder: (context, constraints) {
          final mobile = android && !xbIsDesktopWidth(constraints.maxWidth);
          return ColoredBox(
            color: XbTokens.of(context).sf,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (mobile)
                  const _NodesHeader()
                else
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 14, 20, 10),
                    child: XbScreenTitle('选择线路'),
                  ),
                Expanded(
                  child: _GuestNodes(
                    onTapLogin: widget.onTapLogin,
                    mobile: mobile,
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    // 节点可用性以当前会话的共享同步结果为准，辅以本地 userProfile。
    // 兜底（冷启动尚无刷新结果时）。取两者「更差」的信号 → 任一指示过期/无套餐/用尽即清空节点。
    final profile = ref.watch(userProfileProvider);
    ref.watch(nodeProfileHoldProvider);
    final sub = ref.read(nodeProfileHoldProvider.notifier)
            .forRevision(ref.read(authStateProvider.notifier).sessionRevision) ??
        profile.asData?.value;
    final emptyBody = _resolveEmptyBody(sub);
    if (emptyBody != null) return _emptyShell(emptyBody);

    final adapter = ref.watch(xbNodesAdapterProvider);
    final view = adapter.nodesView(ref);

    // Match upstream's global-mode entry without pinning the user to GLOBAL:
    // subsequent manual group browsing remains available until mode changes.
    if (_lastGlobalMode != view.isGlobal) {
      if (view.isGlobal && (_lastGlobalMode != null || _selectedGroup == null)) {
        _selectedGroup = view.preferredGroupName;
      }
      _lastGlobalMode = view.isGlobal;
    }

    // 无节点时保留空态，刷新状态由顶部按钮表达。
    if (view.isEmpty) {
      final phase = ref.watch(nodeReadPhaseProvider);
      if (phase != NodeReadPhase.idle || ref.watch(interfaceUnavailableProvider) ||
          profile.hasError || profile.isLoading) {
        final loading = phase == NodeReadPhase.loading || (phase != NodeReadPhase.failed && profile.isLoading);
        return _emptyShell(XbEmptyState(
          icon: loading ? Icons.sync : Icons.cloud_off,
          title: loading ? '正在同步线路' : '线路暂未同步',
          description: loading ? '请稍候，正在获取当前账号的线路。' : '请检查网络后刷新节点。',
        ));
      }
      return _emptyShell(_EmptyNodes(onTapRenew: _openShop));
    }

    // Preserve browsing, then use the upstream entry if the selected group disappeared.
    final groups = view.groups;
    final preferred = groups.firstWhere(
      (g) => g.name == view.preferredGroupName,
      orElse: () => groups.first,
    );
    final current = groups.firstWhere(
      (g) => g.name == _selectedGroup,
      orElse: () => preferred,
    );

    // 顶部分组 tab：窄窗口横向；宽窗口 master-detail（左竖排分组栏 + 右双列节点网格，C-分支）。
    final scrollNode =
        (_pendingScrollNode != null &&
            current.nodes.any((n) => n.name == _pendingScrollNode))
        ? _pendingScrollNode
        : null;
    final header = _NodesHeader(
      onRefresh: _refreshNodes,
      refreshing: _refreshing,
      cooldownSec: cooldownSeconds,
    );
    final revision = ref.read(authStateProvider.notifier).sessionRevision;

    final epoch = ref.watch(verifiedRouteEpochProvider);
    if (epoch > _sampledEpoch && current.nodes.isNotEmpty &&
        TickerMode.valuesOf(context).enabled && ModalRoute.isCurrentOf(context) != false) {
      _sampledEpoch = epoch;
      final target = current.nodes.firstWhere((node) => node.name == current.currentSelected,
          orElse: () => current.nodes.first);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || ref.read(verifiedRouteEpochProvider) != epoch ||
            ref.read(authStateProvider.notifier).sessionRevision != revision ||
            !TickerMode.valuesOf(context).enabled || ModalRoute.isCurrentOf(context) == false) {
          return;
        }
        try {
          await adapter.testNode(ref, proxyName: target.name, type: target.type, testUrl: target.testUrl);
        } catch (_) {
          // Leave it unmeasured; never start a group-wide storm on reconnect.
        }
      });
    }
    final nativeMobileGroups = Theme.of(context).platform == TargetPlatform.android;
    return LayoutBuilder(
      builder: (context, constraints) {
        final masterDetail = xbIsDesktopWidth(constraints.maxWidth);
        if (masterDetail) {
          // 标题栏与下方内容区用同一 maxW（同居中限宽）→ 顶部「刷新节点」与分组头「测延迟」
          // 右缘严格对齐（修宽窗口下 md 限 1000 居中、而标题栏全宽导致的错位）。
          final maxW = xbContentMaxWidth(constraints.maxWidth);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 桌面固定标题栏（原型 .chd）：标题「选择线路」+ 右侧刷新，带底部分隔线。
              XbContentHeader(
                title: '选择线路',
                maxContentWidth: maxW,
                trailing: _NodesRefreshAction(
                  onRefresh: _refreshNodes,
                  refreshing: _refreshing,
                  cooldownSec: cooldownSeconds,
                ),
              ),
              Expanded(
                // 原型 .md：max-width 1000 居中，rail 与节点网格之间 20px 留白（无分隔线）。
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: Padding(
                      // 横向 28 与固定标题栏 XbContentHeader（padding 28）对齐 → 顶部「刷新节点」
                      // 与分组头「测延迟」右缘对齐、rail 左缘与标题对齐（原型屏2）。
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _GroupRail(
                            groups: groups,
                            selected: current.name,
                            onSelect: (name) =>
                                setState(() => _selectedGroup = name),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: XbTabRefreshIndicator(
                              onRefresh: _refreshNodes,
                              child: XbNodeGroup(
                                key: ValueKey(current.name),
                                group: current,
                                columns: 2,
                                scrollToNode: scrollNode,
                                scrollNonce: _handledNonce,
                              ),
                            ),
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
        // Android采用原版分组交互；桌面窄窗口仍保留现有横向品牌标签。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!nativeMobileGroups) header,
            if (!nativeMobileGroups)
              _GroupTabBar(
                groups: groups,
                selected: current.name,
                onSelect: (name) => setState(() => _selectedGroup = name),
              ),
            Expanded(
              child: nativeMobileGroups ? XbGroupTabs(
                key: ValueKey((revision, view.isGlobal)),
                groups: groups,
                selected: current.name,
                targetNonce: _handledNonce,
                headerBuilder: (context, group) => _NodesHeader(
                  onRefresh: _refreshNodes,
                  refreshing: _refreshing,
                  cooldownSec: cooldownSeconds,
                  group: group,
                ),
                onSelected: (name) {
                  if (!mounted ||
                      ref.read(authStateProvider) != AuthState.authenticated ||
                      ref.read(authStateProvider.notifier).sessionRevision != revision) {
                    return;
                  }
                  setState(() => _selectedGroup = name);
                },
                groupBuilder: (context, group) => PageStorage(
                  bucket: _groupScrollStorage,
                  child: KeyedSubtree(
                    key: PageStorageKey((revision, group.name)),
                    child: XbTabRefreshIndicator(
                      onRefresh: _refreshNodes,
                      child: XbNodeGroup(
                        key: ValueKey(group.name),
                        group: group,
                        showDelayAction: false,
                        scrollToNode: group.name == current.name ? scrollNode : null,
                        scrollNonce: _handledNonce,
                      ),
                    ),
                  ),
                ),
              ) : XbTabRefreshIndicator(
                onRefresh: _refreshNodes,
                child: XbNodeGroup(
                  key: ValueKey(current.name),
                  group: current,
                  scrollToNode: scrollNode,
                  scrollNonce: _handledNonce,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 桌面 master-detail 左侧分组栏（原型屏2 `.md-rail`）：「线路分组」小标题 + 竖排分组 pill。
class _GroupRail extends StatelessWidget {
  const _GroupRail({
    required this.groups,
    required this.selected,
    required this.onSelect,
  });

  final List<XbGroupSummary> groups;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 160,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 2, 0, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                '线路分组',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            _GroupTabBar(
              groups: groups,
              selected: selected,
              onSelect: onSelect,
              axis: Axis.vertical,
            ),
          ],
        ),
      ),
    );
  }
}

/// 桌面原有分组样式：宽窗口竖排，窄窗口横向chips。Android另用原版交互适配器。
class _GroupTabBar extends StatelessWidget {
  const _GroupTabBar({
    required this.groups,
    required this.selected,
    required this.onSelect,
    this.axis = Axis.horizontal,
  });

  final List<XbGroupSummary> groups;
  final String selected;
  final ValueChanged<String> onSelect;

  /// 桌面窄窗口横向chips（默认），master-detail左栏竖向列表。
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (axis == Axis.vertical) {
      // 桌面左栏：竖向全宽 pill 列表。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final g in groups) ...[
            _chip(context, t, scheme, g, g.name == selected),
            const SizedBox(height: 6),
          ],
        ],
      );
    }
    // 桌面窄窗口保留原横向标签，不接入移动端的新菜单。
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final g = groups[i];
          return _chip(context, t, scheme, g, g.name == selected);
        },
      ),
    );
  }

  /// 单个分组 chip（横/竖通用；竖向左对齐全宽，横向居中自适应）。
  Widget _chip(
    BuildContext context,
    XbTokens t,
    ColorScheme scheme,
    XbGroupSummary g,
    bool on,
  ) {
    final vertical = axis == Axis.vertical;
    return GestureDetector(
      onTap: () => onSelect(g.name),
      child: Container(
        alignment: vertical ? Alignment.centerLeft : Alignment.center,
        padding: vertical
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
            : const EdgeInsets.symmetric(horizontal: 15),
        decoration: BoxDecoration(
          gradient: on
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(
                      Colors.white.withValues(alpha: 0.12),
                      scheme.primary,
                    ),
                    scheme.primary,
                  ],
                )
              : null,
          // 未选：白卡底 + 细描边（清晰是可点 chip，深色下也跳出来）；选中：品牌渐变。
          color: on ? null : t.card,
          border: on ? null : Border.all(color: t.line, width: 1.4),
          borderRadius: BorderRadius.circular(vertical ? 16 : 30),
          boxShadow: on
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.45),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                    spreadRadius: -6,
                  ),
                ]
              : null,
        ),
        // 竖排（桌面分组栏）：名左 + 节点数徽标右（原型 .vtab .cnt）。横排只显示名。
        child: vertical
            ? Row(
                children: [
                  Expanded(
                    child: XbEmojiText(
                      g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: on ? Colors.white : t.on,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _CountBadge(count: g.nodes.length, selected: on),
                ],
              )
            : XbEmojiText(
                g.name,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : t.on,
                ),
              ),
      ),
    );
  }
}

/// 分组栏节点数徽标（原型 `.vtab .cnt`）：选中态白色半透明底，未选 sfc 底。
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: selected ? Colors.white.withValues(alpha: 0.22) : t.sfc,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: selected ? Colors.white : t.onv,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 「选择线路」标题栏：游客态没有操作，移动有分组时显示双操作胶囊。
class _NodesHeader extends StatelessWidget {
  const _NodesHeader({
    this.onRefresh,
    this.refreshing = false,
    this.cooldownSec = 0,
    this.group,
  });

  final VoidCallback? onRefresh;
  final bool refreshing;
  final int cooldownSec;
  final XbGroupSummary? group;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final group = this.group;
    final onRefresh = this.onRefresh;
    final mobileHeader = group != null || onRefresh == null;
    final title = Text(
      '选择线路',
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: t.on,
      ),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: mobileHeader ? 58 : 0),
      child: Padding(
        padding: mobileHeader
            ? const EdgeInsets.symmetric(horizontal: 20)
            : const EdgeInsets.fromLTRB(16, 8, 8, 2),
        child: Row(
          children: [
            if (mobileHeader)
              Expanded(child: title)
            else ...[
              title,
              const Spacer(),
            ],
            if (group != null && onRefresh != null) ...[
              const SizedBox(width: 8),
              Stack(
                key: const ValueKey('nodes-action-capsule'),
                alignment: Alignment.center,
                children: [
                  Positioned(left: 0, right: 0, child: Container(
                    key: const ValueKey('nodes-action-capsule-face'),
                    height: 36,
                    decoration: BoxDecoration(color: t.card, borderRadius: AppRadius.xl),
                  )),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      XbGroupDelayAction(group: group, compact: true),
                      SizedBox(
                        key: const ValueKey('nodes-action-divider'),
                        width: 1,
                        height: 16,
                        child: ColoredBox(color: t.line),
                      ),
                      _NodesRefreshAction(
                        onRefresh: onRefresh,
                        refreshing: refreshing,
                        cooldownSec: cooldownSec,
                        compact: true,
                      ),
                    ],
                  )),
                ],
              ),
            ] else if (onRefresh != null)
              _NodesRefreshAction(
                onRefresh: onRefresh,
                refreshing: refreshing,
                cooldownSec: cooldownSec,
              ),
          ],
        ),
      ),
    );
  }
}

/// 「刷新节点」操作按钮（移动端标题行 / 桌面 .chd 标题栏共用）。
/// 刷新中独立转圈禁用，冷却仍可点；移动胶囊仅在读屏和提示中提供冷却秒数。
class _NodesRefreshAction extends StatelessWidget {
  const _NodesRefreshAction({
    required this.onRefresh,
    this.refreshing = false,
    this.cooldownSec = 0,
    this.compact = false,
  });

  final VoidCallback onRefresh;
  final bool refreshing;
  final int cooldownSec;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final coolingDown = cooldownSec > 0;
    const idle = '刷新节点';
    const busy = '刷新中…';
    final String label;
    if (refreshing) {
      label = busy;
    } else if (coolingDown) {
      label = '$idle ${cooldownSec}s';
    } else {
      label = idle;
    }
    if (compact) {
      return XbNodeCapsuleAction(
        surfaceKey: const ValueKey('node-refresh-press-surface'),
        glyph: AppGlyphs.refresh,
        iconSize: 19,
        label: refreshing ? '刷新中' : idle,
        description: label,
        onTap: refreshing ? null : onRefresh,
        busy: refreshing,
        cooling: !refreshing && coolingDown,
        countdownSeconds: !refreshing && coolingDown ? cooldownSec : null,
      );
    }
    return TextButton.icon(
      // 真正刷新中才禁用（null）；冷却中保持可点 → 触发 _refreshNodes 内的冷却 toast。
      onPressed: refreshing ? null : onRefresh,
      icon: refreshing
          ? null
          : Icon(
              Icons.refresh,
              size: 16,
              color: coolingDown
                  ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                  : scheme.primary,
            ),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: coolingDown
            ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
            : scheme.primary,
        // 与分组头「测延迟」按钮同款紧凑内距 → 两者文字右缘严格对齐。
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 空态：无可用分组 → 引导续费 + 刷新重试（R4.6，复用 XbEmptyState）。
class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes({this.onTapRenew});

  final VoidCallback? onTapRenew;

  @override
  Widget build(BuildContext context) {
    return _NodeAvailabilityPrompt(
      icon: Icons.cloud_off,
      title: '当前无可用线路',
      description: '套餐可能已到期或未生效，\n续费 / 购买套餐后即可同步线路。',
      actionLabel: '前往续费 / 购买',
      actionIcon: Icons.shopping_cart,
      onAction: onTapRenew,
    );
  }
}

/// 游客态：移动版对照 `.guestcta`，其他空态与桌面照旧。
class _GuestNodes extends _NodePrompt {
  const _GuestNodes({required super.mobile, VoidCallback? onTapLogin})
      : super(
          title: '登录后查看专属线路',
          description: '高速节点由服务端下发，\n登录账号即可同步全部线路。',
          icon: Icons.public,
          actionLabel: '立即登录',
          onAction: onTapLogin,
        );
}

class _NodePrompt extends StatelessWidget {
  const _NodePrompt({
    required this.mobile, required this.title, required this.description,
    required this.icon, required this.actionLabel, this.actionIcon, this.onAction,
    this.secondaryLabel, this.onSecondary,
  });
  final bool mobile;
  final String title, description, actionLabel;
  final String? secondaryLabel;
  final IconData icon;
  final IconData? actionIcon;
  final VoidCallback? onAction, onSecondary;

  @override
  Widget build(BuildContext context) {
    final t = XbTokens.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    final accent = secondaryLabel != null ? XbTokens.warn : brand;
    final action = _NodePromptButton(label: actionLabel, icon: actionIcon, onPressed: onAction);
    const headline = AppTextStyle.headline;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          // The prototype centers the guest block in the upper 78% of the
          // body. Let it grow and scroll when fonts are large or space is short.
          constraints: BoxConstraints(minHeight: mobile ? constraints.maxHeight * 0.78 : 0),
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 32, vertical: mobile ? 14 : 54),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    key: actionIcon == null
                        ? ValueKey(mobile ? 'nodes-guest-badge' : 'nodes-desktop-guest-badge')
                        : null,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(XbTokens.rLg),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(accent.withValues(alpha: 0.14), t.sfc),
                          t.sfc,
                        ],
                      ),
                    ),
                    child: SizedBox.square(
                      dimension: mobile ? 80 : 74,
                      child: Icon(icon, size: 36, color: accent),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: mobile ? headline.size : 18,
                      fontWeight: headline.weight,
                      color: t.on,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    description,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppTextStyle.footnote.size,
                      height: 1.65,
                      color: t.onv,
                    ),
                  ),
                  SizedBox(height: mobile ? 14 : 22),
                  if (secondaryLabel == null)
                    action
                  else
                    IntrinsicWidth(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          action,
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 50),
                              backgroundColor: Color.alphaBlend(brand.withValues(alpha: .09), t.card),
                              side: BorderSide(color: brand.withValues(alpha: .30)),
                            ),
                            icon: const Icon(Icons.shopping_cart, size: 18),
                            onPressed: onSecondary,
                            label: Text(secondaryLabel!),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NodePromptButton extends StatelessWidget {
  const _NodePromptButton({required this.label, required this.onPressed, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  static const _loginGlyph = Glyph([
    GlyphPolyline([
      GlyphVertex(12, 4),
      GlyphVertex(20, 4, 1.6),
      GlyphVertex(20, 20, 1.6),
      GlyphVertex(12, 20),
    ], role: GlyphRole.line),
    GlyphPolyline([
      GlyphVertex(3.5, 12),
      GlyphVertex(14.5, 12),
    ], role: GlyphRole.line),
    GlyphPolyline([
      GlyphVertex(10.5, 8),
      GlyphVertex(14.5, 12, 0.4),
      GlyphVertex(10.5, 16),
    ], role: GlyphRole.line),
  ], matchTextDirection: true);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = theme.colorScheme.primary;
    const buttonText = AppTextStyle.subheadline;

    return XbGradientAction(
        key: icon == null ? const ValueKey('nodes-guest-login-gradient') : null,
        onPressed: onPressed,
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
        keepMaterialDisabled: true,
        shadow: BoxShadow(
          color: brand.withValues(alpha: 0.32),
          offset: const Offset(0, 6),
          blurRadius: 16,
          spreadRadius: -8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null)
              Icon(icon, size: 18)
            else const GlyphIcon(
              _loginGlyph,
              size: 18,
              fill: 1,
            ),
            const SizedBox(width: 7),
            Flexible(child: Text(label, textAlign: TextAlign.center,
                style: TextStyle(fontSize: buttonText.size, fontWeight: buttonText.emphasizedWeight))),
          ],
        ),
    );
  }
}

/// 流量用尽空态（原型桌面屏26b / 移动屏10a）：套餐流量已用尽 → 清空节点，引导
/// 购买流量包恢复本周期流量，或购买 / 更改套餐。复用 XbEmptyState（主+次按钮）。
class _ExhaustedNodes extends StatelessWidget {
  const _ExhaustedNodes({this.onBuyResetPack, this.onBuyPlan});

  /// 购买流量包（恢复本周期流量）。
  final VoidCallback? onBuyResetPack;

  /// 购买 / 更改套餐。
  final VoidCallback? onBuyPlan;

  @override
  Widget build(BuildContext context) {
    return _NodeAvailabilityPrompt(
      icon: Icons.warning_amber_rounded,
      title: '当前套餐流量已用尽',
      description: '流量用尽后线路暂不可用。\n可重置流量恢复本周期流量，或购买 / 更改其他套餐。',
      actionLabel: '重置流量',
      actionIcon: Icons.bolt,
      onAction: onBuyResetPack,
      secondaryLabel: '购买 / 更改套餐',
      onSecondary: onBuyPlan,
    );
  }
}

/// Narrow Android prompts share the guest panel's geometry; other surfaces
/// retain their existing empty-state layout and pull-to-refresh scroll view.
class _NodeAvailabilityPrompt extends StatelessWidget {
  const _NodeAvailabilityPrompt({
    required this.icon, required this.title, required this.description,
    required this.actionLabel, required this.actionIcon, this.onAction,
    this.secondaryLabel, this.onSecondary,
  });
  final IconData icon, actionIcon;
  final String title, description, actionLabel;
  final String? secondaryLabel;
  final VoidCallback? onAction, onSecondary;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (Theme.of(context).platform == TargetPlatform.android &&
          !xbIsDesktopWidth(constraints.maxWidth)) {
        return _NodePrompt(
          mobile: true, title: title, description: description, icon: icon,
          actionLabel: actionLabel, actionIcon: actionIcon, onAction: onAction,
          secondaryLabel: secondaryLabel, onSecondary: onSecondary,
        );
      }
      return XbEmptyState(
        icon: icon, title: title, description: description,
        actionLabel: actionLabel, actionIcon: actionIcon, onAction: onAction,
        secondaryLabel: secondaryLabel, secondaryIcon: Icons.shopping_cart,
        onSecondary: onSecondary,
      );
    },
  );
}
