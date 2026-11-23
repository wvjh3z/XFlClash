import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers/invite_provider.dart';
import '../widgets/xb_async_view.dart';
import '../widgets/xb_components.dart';
import '../widgets/xb_network_read_recovery.dart';

/// Keep a painted snapshot only for this route and this account/service.
class CommissionReadView<T extends Object> extends ConsumerStatefulWidget {
  const CommissionReadView({
    super.key, required this.data, required this.reload, required this.content,
    required this.errorText, required this.skeleton, this.onPull,
  });
  final AsyncValue<T> data;
  final Future<void> Function() reload;
  final Widget Function(BuildContext, T) content;
  final String errorText;
  final XbSkeletonKind skeleton;
  final VoidCallback? onPull;

  @override
  ConsumerState<CommissionReadView<T>> createState() => _CommissionReadState<T>();
}

class _CommissionReadState<T extends Object> extends ConsumerState<CommissionReadView<T>> {
  Object? _owner;
  T? _snapshot;
  bool _refreshing = false;
  bool _recoverAfterRead = false;

  Future<void> _refresh() async {
    if (!mounted || _refreshing || widget.data.isLoading ||
        _owner != ref.read(commissionReadOwnerProvider)) {
      return;
    }
    _refreshing = true;
    try {
      await widget.reload();
    } catch (_) {
      // Provider exposes the failure with the appropriate error state.
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(commissionReadOwnerProvider);
    if (_owner != owner) {
      _snapshot = null;
      _recoverAfterRead = false;
      _owner = owner;
    }
    final data = widget.data;
    if (!data.isLoading && !data.hasError && data.asData != null) {
      _snapshot = data.requireValue;
    }
    xbListenForReadRecovery(context, ref, () {
      if (widget.data.isLoading) { _recoverAfterRead = true; }
      else if (xbIsRecoverableReadError(widget.data.error)) { _refresh(); }
    });
    if (_recoverAfterRead && !data.isLoading) {
      _recoverAfterRead = false;
      if (xbIsRecoverableReadError(data.error)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && owner == ref.read(commissionReadOwnerProvider) &&
              ModalRoute.of(context)?.isCurrent == true && TickerMode.valuesOf(context).enabled &&
              (WidgetsBinding.instance.lifecycleState == null ||
               WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed)) {
            _refresh();
          }
        });
      }
    }
    final snapshot = _snapshot;
    return RefreshIndicator(
      onRefresh: () async {
        widget.onPull?.call();
        await _refresh();
      },
      child: snapshot == null
          ? XbAsyncView(
              loading: data.isLoading, error: data.error,
              errorFallback: widget.errorText, skeleton: widget.skeleton,
              onRetry: _refresh,
              builder: (_) => const SizedBox.shrink(),
            )
          : Column(children: [
              if (data.isLoading) const LinearProgressIndicator(minHeight: 2),
              if (data.hasError)
                TextButton(onPressed: _refresh, child: Text('${widget.errorText}，当前显示上次数据 · 重试')),
              Expanded(child: widget.content(context, snapshot)),
            ]),
    );
  }
}
