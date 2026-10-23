import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:proxy/proxy.dart';

final proxy = system.isDesktop && !safeModeBuild ? Proxy() : null;

final systemProxyQueue = proxy == null ? null : SystemProxyQueue(proxy!);

/// Exit's stop goes through the same queue as every other change, so a start
/// still waiting behind a slow call cannot turn the proxy back on after it.
class SystemProxyQueue {
  final Proxy _proxy;
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _startedHere = false;
  final bool _ownedOnly;

  SystemProxyQueue(
    this._proxy, {
    bool ownedOnly = const String.fromEnvironment('XB_NATIVE_ID') != '',
  }) : _ownedOnly = ownedOnly;

  Future<bool> _stopOwned() async {
    if (_ownedOnly && !_startedHere) return true;
    final stopped = await _proxy.stopProxy();
    if (stopped) _startedHere = false;
    return stopped;
  }

  Future<void> apply(ProxyState state) {
    return _enqueue(() async {
      if (_closed) {
        return;
      }
      final bool applied;
      if (state.isStart && state.systemProxy) {
        // A failed start can still have changed the OS setting; retain cleanup ownership.
        _startedHere = true;
        applied = await _proxy.startProxy(state.port, state.bassDomain);
      } else {
        applied = await _stopOwned();
      }
      if (!applied) {
        commonPrint.log(
          'update system proxy failed',
          logLevel: LogLevel.warning,
        );
      }
    });
  }

  Future<void> close() {
    _closed = true;
    return _enqueue(() async {
      await _stopOwned();
    });
  }

  Future<void> _enqueue(Future<void> Function() task) {
    return _tail = _tail.then((_) => task()).catchError((Object error) {
      commonPrint.log(
        'update system proxy failed: $error',
        logLevel: LogLevel.warning,
      );
    });
  }
}

String proxyEnvCommand(int port, {required bool isWindows}) {
  final url = 'http://127.0.0.1:$port';
  return isWindows ? 'set \$env:all_proxy=$url' : 'export all_proxy=$url';
}
