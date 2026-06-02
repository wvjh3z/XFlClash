/// 4 状态统一组件（NFR-2 / F168）：loading / error / empty / offline。
///
/// 所有 Xboard 页面用此组件统一渲染异步状态，避免各页重复写 loading/error UI（NFR-2 可维护性）。
/// error 态按 `XbDomainError` 7 子类型分流不同 UI（design L1416-1444）。
///
/// **offline 检测**：传入 `isOffline`（上层从 `xboardConnectivityProvider` 读，W5.4 完成前用 fake）；
/// 本组件不裸 listen connectivity（DD-5 单一数据源）。
library;

import 'package:flutter/material.dart';

import '../l10n/xboard_business_messages.dart';
import '../models/xb_domain_error.dart';
import '../util/error_text.dart';

/// Xboard 4 状态视图。
class XboardStateView<T> extends StatelessWidget {
  const XboardStateView({
    super.key,
    required this.state,
    required this.onData,
    this.onRetry,
    this.isOffline = false,
    this.isEmpty,
    this.locale = XbLocale.zhCN,
  });

  /// 异步状态（loading / data / error 三态由 AsyncSnapshot 风格表达）。
  final XbViewState<T> state;

  /// data 态渲染。
  final Widget Function(T data) onData;

  /// 重试回调（error / offline 态显示重试按钮时用）。
  final VoidCallback? onRetry;

  /// 是否离线（上层从 connectivity 读）。
  final bool isOffline;

  /// 自定义空判定（默认非空）。
  final bool Function(T data)? isEmpty;

  /// 当前 locale（错误文案本地化）。
  final XbLocale locale;

  @override
  Widget build(BuildContext context) {
    // offline 优先级最高（断网时即便有 stale data 也提示离线 banner，由上层决定是否仍展示 data）
    if (isOffline && state is! XbViewData<T>) {
      return _OfflineView(onRetry: onRetry);
    }
    return switch (state) {
      XbViewLoading<T>() => const Center(child: CircularProgressIndicator()),
      XbViewError<T>(:final error) =>
        _ErrorView(error: error, onRetry: onRetry, locale: locale),
      XbViewData<T>(:final data) =>
        (isEmpty?.call(data) ?? false) ? const _EmptyView() : onData(data),
    };
  }
}

/// 视图状态 sealed（loading / data / error）。
sealed class XbViewState<T> {
  const XbViewState();
}

final class XbViewLoading<T> extends XbViewState<T> {
  const XbViewLoading();
}

final class XbViewData<T> extends XbViewState<T> {
  final T data;
  const XbViewData(this.data);
}

final class XbViewError<T> extends XbViewState<T> {
  final XbDomainError error;
  const XbViewError(this.error);
}

class _OfflineView extends StatelessWidget {
  const _OfflineView({this.onRetry});
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 8),
            const Text('当前离线，部分数据可能陈旧'),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('暂无数据'));
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, this.onRetry, required this.locale});
  final XbDomainError error;
  final VoidCallback? onRetry;
  final XbLocale locale;

  @override
  Widget build(BuildContext context) {
    // error 态按 XbDomainError 子类型分流文案（统一走 resolveErrorText，透传后端 message）。
    // XbUnauthorized 例外：不显示重试（UI 上层据此跳登录）。
    final text = resolveErrorText(error, fallback: '出错了', locale: locale);
    final showRetry = errorAllowsRetry(error);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(text, textAlign: TextAlign.center),
          ),
          if (showRetry && onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
