/// 形态 A 异步四分支视图（行为层抽象：loading / retrying / error / data）。
///
/// **背景（批次二反思）**：`加载中spinner / 重试中黄横幅 / 失败重试 / 空态 / 数据` 这套四~五分支
/// 在 plan_list / order_list / reset_traffic / order_payment 重复手写（FutureBuilder 版 + 手写
/// `_loading` 版两套），且「重试中显示黄横幅」「错误文案解析」逻辑各写一遍易飘。本组件收口为
/// **纯展示组件**——只按传入状态选分支渲染，**不绑定 Future/Provider**（刻意避开
/// `provider.future` 挂起、keepAlive `AsyncLoading(error:)` 等 async 边界坑：状态由调用方持有，
/// 本组件不 await 任何东西）。
///
/// **契约（已被 xb_async_view_test 锁定）**：
/// 1. 分支优先级固定：retrying > loading > error > data。
///    - retrying=true → 永远显示「正在刷新服务」黄横幅（无论 loading/error）。
///    - 否则 loading=true → spinner。
///    - 否则 error!=null → 失败重试块（XbErrorRetry，文案经 resolveErrorText 解析）。
///    - 否则 → data builder。
/// 2. 纯函数式：相同入参渲染相同输出，无副作用、无异步。
/// 3. error 文案：XbDomainError 经 resolveErrorText 解析；非领域错误用 fallback。
library;

import 'package:flutter/material.dart';

import '../models/xb_domain_error.dart';
import '../util/error_text.dart';
import 'xb_components.dart'
    show XbSyncBanner, XbErrorRetry, XbSkeletonView, XbSkeletonKind;

/// 异步四分支纯展示组件。状态由调用方持有（Future/Provider/手写 bool 皆可）。
class XbAsyncView extends StatelessWidget {
  const XbAsyncView({
    super.key,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.builder,
    this.retrying = false,
    this.retryingText = '正在刷新服务，请稍候…',
    this.errorFallback = '加载失败',
    this.loadingWidget,
    this.skeleton,
  });

  /// 首次加载中（非重试）。
  final bool loading;

  /// 重试中（点重试后到落定前）→ 显示「正在刷新服务」黄横幅（优先级最高）。
  final bool retrying;

  /// 错误对象（null = 无错误）。XbDomainError 会经 resolveErrorText 解析文案。
  final Object? error;

  /// 失败重试块「重试」回调。
  final VoidCallback onRetry;

  /// 数据态内容构造（仅 !loading && !retrying && error==null 时调用）。
  final WidgetBuilder builder;

  /// 重试横幅文案（默认「正在刷新服务，请稍候…」）。
  final String retryingText;

  /// 错误兜底文案（error 非 XbDomainError 时）。
  final String errorFallback;

  /// 自定义首次加载 widget（优先级高于 [skeleton]；默认居中 spinner）。
  final Widget? loadingWidget;

  /// 首次加载骨架屏形态（框架化）：设了它，loading 分支自动渲染对应 [XbSkeletonView]，
  /// 各页无需手写骨架。[loadingWidget] 非空时优先用 loadingWidget。
  final XbSkeletonKind? skeleton;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // 各分支带稳定 key → AnimatedSwitcher 在 骨架/重试/错误 → 数据 间做淡入淡出 crossfade，
    // 避免骨架瞬切到内容的生硬跳变。settle 后只剩目标分支满不透明度（golden 安全）。
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(
        key: ValueKey(_branchKey),
        child: _buildBranch(context),
      ),
    );
  }

  /// 当前分支标识（驱动 AnimatedSwitcher 切换）。
  String get _branchKey {
    if (retrying) return 'retrying';
    if (loading) return 'loading';
    if (error != null) return 'error';
    return 'data';
  }

  Widget _buildBranch(BuildContext context) {
    // 1. 重试中（优先级最高）：黄横幅。
    if (retrying) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [XbSyncBanner(text: retryingText)],
      );
    }
    // 2. 首次加载：自定义 widget > 骨架屏 > 默认 spinner。
    if (loading) {
      if (loadingWidget != null) return loadingWidget!;
      if (skeleton != null) return XbSkeletonView(kind: skeleton!);
      return const Center(child: CircularProgressIndicator());
    }
    // 3. 错误：失败重试块（领域错误解析文案）。
    final err = error;
    if (err != null) {
      final msg = err is XbDomainError
          ? resolveErrorText(err, fallback: errorFallback)
          : errorFallback;
      return XbErrorRetry(message: msg, onRetry: onRetry);
    }
    // 4. 数据态。
    return builder(context);
  }
}
