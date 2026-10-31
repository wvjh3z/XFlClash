import 'dart:async';

import 'exit_ip_probe.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final xbUpdateRegionLookupFactoryProvider =
    Provider<XbUpdateRegionLookup Function()>(
      (_) =>
          () => XbUpdateRegionLookup(),
    );

/// A click owns a fresh, independent probe; never updates the home IP provider.
class XbUpdateRegionLookup {
  XbUpdateRegionLookup({XbExitIpProbe? probe})
    : _probe =
          probe ??
          XbExitIpProbe(
            timeout: const Duration(seconds: 3),
            requireCountry: true,
          );

  final XbExitIpProbe _probe;
  bool _cancelled = false;

  Future<String?> run() async {
    try {
      final result = await _probe.run().timeout(const Duration(seconds: 3));
      return _cancelled ? null : result?.countryCode;
    } on Exception {
      return null;
    } finally {
      _probe.cancel();
    }
  }

  void cancel() {
    _cancelled = true;
    _probe.cancel();
  }
}
