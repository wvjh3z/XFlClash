import 'dart:async';

import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show mapEquals, ValueNotifier;

import '../services/exit_ip_probe.dart';
import '../services/crisp_client_ip.dart';
import 'network_recovery_provider.dart';

/// Passive projection: reading this does not instantiate the seven-source probe.
final supportExitIpProvider = Provider<ValueNotifier<String?>>((ref) {
  final signal = ValueNotifier<String?>(null);
  ref.onDispose(signal.dispose);
  return signal;
});

class XbExitIpState {
  const XbExitIpState({this.loading = false, this.result, this.failed = false});
  final bool loading;
  final bool failed;
  final XbExitIpResult? result;
}

final xbExitIpProbeFactoryProvider = Provider<XbExitIpProbe Function()>(
  (ref) => XbExitIpProbe.new,
);
final xbExitIpProvider =
    NotifierProvider.autoDispose<XbExitIpNotifier, XbExitIpState>(
      XbExitIpNotifier.new,
    );

class XbExitIpNotifier extends Notifier<XbExitIpState> {
  XbExitIpProbe? _probe;
  Timer? _debounce;
  int _generation = 0;
  bool _needsRefresh = true;

  @override
  XbExitIpState build() {
    final supportIp = ref.watch(supportExitIpProvider);
    final tracker = ref.read(routeTrackerProvider.notifier);
    var attached = false;
    ref.onDispose(() {
      supportIp.value = null;
      _generation++;
      _debounce?.cancel();
      _probe?.cancel();
      if (attached) tracker.detach();
    });
    ref.listen(isStartProvider, (_, _) => refresh());
    ref.listen(verifiedRouteEpochProvider, (_, _) => refresh(preserveResult: true));
    ref.listen(suspendProvider, (_, _) => refresh());
    ref.listen(
      patchClashConfigProvider.select((s) => s.mode),
      (_, _) => refresh(),
    );
    ref.listen(
      patchClashConfigProvider.select((s) => s.mixedPort),
      (_, _) => refresh(),
    );
    ref.listen(
      networkSettingProvider.select((s) => s.authentication),
      (_, _) => refresh(),
    );
    ref.listen(selectedMapProvider, (previous, next) {
      if (!mapEquals(previous, next)) refresh();
    });
    // Route snapshots are notifications only: a non-live tracker never blocks
    // direct HTTP lookup (unlike the upstream core-backed IP probe).
    ref.listen(routeTrackerProvider, (previous, next) {
      if (previous != null &&
          previous.coreEpoch == next.coreEpoch &&
          previous.routeVersion == next.routeVersion &&
          previous.hostEpoch == next.hostEpoch) {
        return;
      }
      // First subscription is not evidence that an already measured direct
      // route changed. Later host/core epoch changes invalidate the old IP.
      final firstSync =
          previous != null &&
          !previous.synced &&
          previous.coreEpoch == 0 &&
          next.synced;
      final invalidated =
          !firstSync &&
          (previous == null ||
              previous.coreEpoch != next.coreEpoch ||
              previous.hostEpoch != next.hostEpoch);
      refresh(preserveResult: !invalidated);
    });
    ref.listen(appVisibleProvider, (_, visible) {
      if (visible) {
        if (_needsRefresh) refresh(preserveResult: true);
      } else {
        // Opening native chat may hide Flutter; visibility alone is not a route change.
        _cancel();
        state = XbExitIpState(result: state.result, failed: state.failed);
      }
    });
    final initial = _generation;
    scheduleMicrotask(() {
      if (!ref.mounted) return;
      tracker.attach();
      attached = true;
      if (_generation == initial) refresh();
    });
    return const XbExitIpState(loading: true);
  }

  void _cancel() {
    _generation++;
    _debounce?.cancel();
    _debounce = null;
    _probe?.cancel();
    _probe = null;
  }

  /// Automatic triggers coalesce as in 0.8.93. Manual retry is immediate.
  void refresh({bool immediate = false, bool preserveResult = false}) {
    _needsRefresh = true;
    ref.read(supportExitIpProvider).value = null;
    final previousResult = preserveResult ? state.result : null;
    // Route changes remain pending while hidden. Visibility alone does not
    // invalidate a successful result; cancelled/failed rounds still need work.
    _cancel();
    final generation = _generation;
    if (!ref.read(appVisibleProvider)) {
      state = XbExitIpState(result: previousResult);
      return;
    }
    state = XbExitIpState(loading: true, result: previousResult);
    if (immediate) {
      unawaited(_run(generation));
    } else {
      _debounce = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(_run(generation)),
      );
    }
  }

  Future<void> _run(int generation) async {
    if (!ref.mounted || generation != _generation) return;
    try {
      final probe = ref.read(xbExitIpProbeFactoryProvider)();
      _probe = probe;
      final result = await probe.run();
      if (!ref.mounted || generation != _generation) return;
      _needsRefresh = result == null;
      ref.read(supportExitIpProvider).value = crispClientIp(result);
      state = XbExitIpState(
        result: result ?? state.result,
        failed: result == null,
      );
    } on Exception {
      if (ref.mounted && generation == _generation) {
        state = XbExitIpState(result: state.result, failed: true);
      }
    } finally {
      if (generation == _generation) {
        _probe?.cancel();
        _probe = null;
      }
    }
  }
}
