/// Brand-owned network events; independent of UI tab lifetimes.
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/providers/state.dart'
    show isStartProvider, suspendProvider;
import '../providers/xboard_connectivity_provider.dart';
import 'endpoint_race_controller.dart';

class XboardNetworkObserver {
  XboardNetworkObserver(
    ProviderContainer container,
    this._race, {
    this.onEffectiveVpnChanged,
    this.onProbeRound,
  }) {
    _vpn = container.listen<bool>(_effectiveVpnProvider, (_, active) {
      final previous = _active;
      _active = active;
      if (previous != active) {
        _race.setVpnActive(active, rerace: false);
        // Initial false is already the controller default; bootstrap owns its race.
        if (previous != null || active) {
          _schedule();
        }
        onEffectiveVpnChanged?.call(previous, active);
      }
    }, fireImmediately: true);
    _network = container.listen<AsyncValue<List<ConnectivityResult>>>(
      xboardConnectivityProvider,
      (_, next) {
        // Loading/errors are unknown, not proof of a disconnected network.
        if (next is AsyncError<List<ConnectivityResult>>) {
          container.read(interfaceUnavailableProvider.notifier).set(false);
          _online =
              true; // Unknown must not permanently disable VPN-triggered races.
          return;
        }
        if (next is! AsyncData<List<ConnectivityResult>>) {
          return;
        }
        final values = next.value.toSet();
        container.read(interfaceUnavailableProvider.notifier).set(
          values.length == 1 && values.contains(ConnectivityResult.none),
        );
        final physical =
            values
                .where(
                  (v) =>
                      v != ConnectivityResult.vpn &&
                      v != ConnectivityResult.none,
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));
        if (physical.isEmpty && !values.contains(ConnectivityResult.none)) {
          return;
        }
        final key = physical.map((v) => v.name).join(',');
        if (key == _physical) {
          return;
        }
        _physical = key;
        _online = physical.isNotEmpty;
        _race.networkChanged(rerace: false);
        _schedule();
      },
      fireImmediately: true,
    );
  }

  static final _effectiveVpnProvider = Provider<bool>(
    (ref) => ref.watch(isStartProvider) && !ref.watch(suspendProvider),
  );
  final EndpointRaceController _race;
  final void Function(bool? previous, bool active)? onEffectiveVpnChanged;
  final void Function()? onProbeRound;
  late final ProviderSubscription<bool> _vpn;
  late final ProviderSubscription<AsyncValue<List<ConnectivityResult>>>
  _network;
  Timer? _timer;
  bool? _active;
  String? _physical;
  bool _online = true;
  bool _disposed = false;

  void _schedule() {
    _timer?.cancel();
    if (!_online || _disposed) {
      return;
    }
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (!_disposed) {
        _race.armNetworkRecovery();
        _race.refreshRaceInBackground();
        onProbeRound?.call();
      }
    });
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _timer?.cancel();
    _vpn.close();
    _network.close();
  }
}
