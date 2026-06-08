/// 测试桩：override networkDetectionProvider，避免 startCheck 触发真实 Debouncer/Timer + 网络。
library;

import 'package:fl_clash/models/models.dart' show IpInfo, NetworkDetectionState;
import 'package:fl_clash/providers/app.dart'
    show networkDetectionProvider, NetworkDetection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 假 NetworkDetection：固定 state，startCheck 空操作（不起 Timer）。
class FakeNetworkDetection extends NetworkDetection {
  FakeNetworkDetection(this._state);
  final NetworkDetectionState _state;

  @override
  NetworkDetectionState build() => _state;

  @override
  void startCheck() {
    // no-op：测试环境不触发真实检测。
  }
}

/// 默认桩 override（已检测到香港出口 IP）。返回类型用推断避开 Override 类型名解析问题。
netDetectionOverride({
  bool loading = false,
  String? ip = '47.243.10.20',
  String? countryCode = 'HK',
}) {
  final state = NetworkDetectionState(
    isLoading: loading,
    ipInfo: (ip != null && countryCode != null)
        ? IpInfo(ip: ip, countryCode: countryCode)
        : null,
  );
  return networkDetectionProvider.overrideWith(
    () => FakeNetworkDetection(state),
  );
}
