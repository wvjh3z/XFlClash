/// 测试期 `connectivity_plus` fake —— 可控的 connectivity 流 + 当前态。
///
/// **关联**：design §C / DD-5（connectivity 独立监听）/ R11 离线 banner / R15 网络变化重选。
///
/// 用途：
/// - 测 `xboardConnectivityProvider`（StreamProvider 订阅 onConnectivityChanged）。
/// - `emit(...)` 推送网络变化（none / wifi / mobile / vpn 切换），驱动离线 banner /
///   首次离线 splash（合规 §F）/ EndpointRace 重选（R15.C.21）。
///
/// `extends Mock implements Connectivity`：手写覆盖 onConnectivityChanged + checkConnectivity
/// 提供真实 broadcast 语义，其余成员 mocktail noSuchMethod 兜底。
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:mocktail/mocktail.dart';

class FakeConnectivity extends Mock implements Connectivity {
  FakeConnectivity({
    List<ConnectivityResult> initial = const [ConnectivityResult.wifi],
  }) : _current = initial;

  final StreamController<List<ConnectivityResult>> _controller =
      StreamController<List<ConnectivityResult>>.broadcast();

  List<ConnectivityResult> _current;

  /// 推送一次网络变化（同时更新 checkConnectivity 的返回值）。
  void emit(List<ConnectivityResult> results) {
    _current = results;
    _controller.add(results);
  }

  /// 常用快捷方法。
  void goOffline() => emit(const [ConnectivityResult.none]);

  void goWifi() => emit(const [ConnectivityResult.wifi]);

  void goMobile() => emit(const [ConnectivityResult.mobile]);

  void goVpn() => emit(const [ConnectivityResult.vpn]);

  /// 测试结束释放（避免 pending timer / stream leak）。
  Future<void> close() => _controller.close();

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => _current;
}
