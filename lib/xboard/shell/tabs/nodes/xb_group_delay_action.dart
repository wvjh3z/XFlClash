import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../widgets/xb_components.dart' show XbSpinner;
import '../../../widgets/xb_feedback.dart' show xbToast;
import '../../../widgets/xb_theme.dart' show XbTokens;
import '../../adapters/xb_nodes_adapter.dart';

// Shared across groups and tab lifetimes. Use monotonic elapsed time, not wall time.
final _cooldown = ValueNotifier<Stopwatch?>(null);

int _remaining() {
  final clock = _cooldown.value;
  return clock == null ? 0 : (60 - clock.elapsed.inSeconds).clamp(0, 60);
}

/// The same group test and cooldown for the Android toolbar and desktop text action.
class XbGroupDelayAction extends ConsumerStatefulWidget {
  const XbGroupDelayAction({
    super.key,
    required this.group,
    this.compact = false,
  });

  final XbGroupSummary group;
  final bool compact;

  @override
  ConsumerState<XbGroupDelayAction> createState() => _XbGroupDelayActionState();
}

class _XbGroupDelayActionState extends ConsumerState<XbGroupDelayAction> {
  // The toolbar survives a group switch. Keep progress with its originating group.
  final _running = <String, ({int done, int total})>{};
  Timer? _ticker;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _cooldown.addListener(_cooldownChanged);
    _seconds = _remaining();
    _startTicker();
  }

  void _cooldownChanged() {
    if (!mounted) return;
    setState(() => _seconds = _remaining());
    _startTicker();
  }

  void _startTicker() {
    _ticker?.cancel();
    if (_seconds == 0) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds = _remaining());
      if (_seconds == 0) _ticker?.cancel();
    });
  }

  @override
  void dispose() {
    _cooldown.removeListener(_cooldownChanged);
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _test() async {
    final group = widget.group;
    final progress = _running[group.name];
    if (progress != null) {
      if (widget.compact) {
        xbToast(context, '测速中，请稍候');
      }
      return;
    }
    if (_remaining() > 0) {
      xbToast(context, '延迟刚刚测试过，请勿频繁测试，您可以点击单个节点进行测试延迟');
      return;
    }
    if (group.nodes.isEmpty) return;
    setState(() => _running[group.name] = (done: 0, total: group.nodes.length));
    try {
      await ref.read(xbNodesAdapterProvider).testGroupDelay(
        ref,
        group.name,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() => _running[group.name] = (done: done, total: total));
        },
      );
    } catch (_) {
      // Preserve the existing group action's error/cooldown policy.
    } finally {
      // Completion still starts the shared cooldown after this owner is retired.
      _cooldown.value = Stopwatch()..start();
      if (mounted) setState(() => _running.remove(group.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = _running[widget.group.name];
    final testing = progress != null;
    final cooling = !testing && _seconds > 0;
    final label = testing
        ? (widget.compact ? '测速中' : '测速中 ${progress.done}/${progress.total}')
        : cooling ? '测延迟 ${_seconds}s' : '测延迟';

    if (!widget.compact) {
      final color = cooling
          ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
          : scheme.primary;
      return TextButton.icon(
        onPressed: testing || widget.group.nodes.isEmpty ? null : _test,
        icon: testing
            ? const XbSpinner(color: XbTokens.warn, size: 13, stroke: 2)
            : Icon(Icons.bolt, size: 16, color: color),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: scheme.primary.withValues(alpha: 0.7),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    final t = XbTokens.of(context);
    final color = cooling ? t.onv : scheme.primary;
    return Tooltip(
      message: '${widget.group.name} · $label',
      child: Semantics(
        label: '${widget.group.name} · $label',
        button: true,
        enabled: widget.group.nodes.isNotEmpty,
        onTap: widget.group.nodes.isEmpty ? null : _test,
        excludeSemantics: true,
        child: SizedBox(
          width: 44,
          height: 44,
          child: InkResponse(
            onTap: widget.group.nodes.isEmpty ? null : _test,
            customBorder: const CircleBorder(),
            child: Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.transparent,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (testing)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                          backgroundColor: t.sfc,
                        ),
                      ),
                    if (cooling)
                      Padding(
                        padding: const EdgeInsets.all(5),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${_seconds}s',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                    else if (!testing)
                      Icon(Icons.bolt, size: 18, color: color),
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
