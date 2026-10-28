import 'dart:async';

import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show mapEquals;

import '../services/exit_ip_probe.dart';

class XbExitIpState {
  const XbExitIpState({this.loading = false, this.result});
  final bool loading;
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

  @override
  XbExitIpState build() {
    final tracker = ref.read(routeTrackerProvider.notifier);
    var attached = false;
    ref.onDispose(() {
      _generation++;
      _debounce?.cancel();
      _probe?.cancel();
      if (attached) tracker.detach();
    });
    ref.listen(isStartProvider, (_, _) => refresh());
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
    ref.listen(
      routeTrackerProvider.select(
        (s) => (s.coreEpoch, s.routeVersion, s.hostEpoch),
      ),
      (_, _) => refresh(),
    );
    ref.listen(appVisibleProvider, (_, visible) {
      if (visible) {
        refresh();
      } else {
        _cancel();
        state = const XbExitIpState();
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
  void refresh({bool immediate = false}) {
    _cancel();
    final generation = _generation;
    if (!ref.read(appVisibleProvider)) {
      state = const XbExitIpState();
      return;
    }
    state = const XbExitIpState(loading: true);
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
      state = XbExitIpState(result: result);
    } on Exception {
      if (ref.mounted && generation == _generation) {
        state = const XbExitIpState();
      }
    } finally {
      if (generation == _generation) {
        _probe?.cancel();
        _probe = null;
      }
    }
  }
}
