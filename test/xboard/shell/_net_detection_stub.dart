/// Controlled Xboard IP view for widget tests; no real core probe or network.
library;

import 'package:fl_clash/xboard/shell/adapters/xb_network_adapter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FakeNetworkAdapter extends XbNetworkAdapter {
  const FakeNetworkAdapter(this.status);
  final XbIpStatus status;
  @override
  XbIpStatus ipStatus(WidgetRef ref) => status;
  @override
  void startCheck(WidgetRef ref) {}
  @override
  void forceCheck(WidgetRef ref) {}
}

netDetectionOverride({
  bool loading = false,
  String? ip = '47.243.10.20',
  String? countryCode = 'HK',
}) => xbNetworkAdapterProvider.overrideWithValue(
  FakeNetworkAdapter(XbIpStatus(loading: loading, ip: ip, countryCode: countryCode)),
);
