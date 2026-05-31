/// IpMirror NAT 多出口预热（R7.13.bis / F386 / Property 17）。
///
/// **fire-and-forget，错误静默，全部不可达也不影响任何功能**（用户 2026-05-27 锁定）。
///
/// **与 Bootstrap 解决不同问题（Property 18）**：Bootstrap subscription_endpoints 解决「网络
/// 可达性」；IpMirror mirror_urls 解决「身份授权」（多 NAT 出口 IP 全记 IpAuth 白名单，解决
/// 中国移动多 NAT 出口被 max_ip_count=2 拦截）。二者独立。
///
/// 经反腐层 [XboardService]（非直连 SDK）：fetchMirrorList 返 XbResult（DD-3 归一）；
/// fireAllMirrors 返 void（接口不收 timeoutPerUrl，per-URL 超时由 SDK adapter 处理，第 12 轮）。
library;

import '../models/xb_domain_types.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';

class IpMirrorPrewarmer {
  IpMirrorPrewarmer({
    required XboardService service,
    DateTime Function()? clock,
  })  : _service = service,
        _now = clock ?? DateTime.now;

  final XboardService _service;
  final DateTime Function() _now;

  DateTime? _lastFireAt;

  /// 预热（fire-and-forget，Property 17 不阻塞）。
  /// [justLoggedIn] true 绕过节流（登录/注册即刻预热）。
  Future<void> prewarm({bool justLoggedIn = false}) async {
    final result = await _service.fetchMirrorList();
    if (result is! XbSuccess<IpMirrorConfigUi>) return; // 失败/超时静默吞。
    final cfg = result.data;
    if (!cfg.enabled || cfg.urls.isEmpty) return;

    final now = _now();
    if (!justLoggedIn && _lastFireAt != null) {
      final elapsed = now.difference(_lastFireAt!);
      if (elapsed < cfg.throttle) return; // 节流期内跳过。
    }

    _service.fireAllMirrors(cfg.urls); // fire-and-forget（接口返 void）。
    _lastFireAt = now;
  }
}
