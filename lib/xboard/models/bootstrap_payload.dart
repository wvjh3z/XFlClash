/// Bootstrap 解密后内层 payload（R15 / D58）。
///
/// v0.1 **只消费** `api_endpoints` + `subscription_endpoints` 两字段（D17）；v0.2/v0.3 的
/// `commands` / `announcements` / `client_update` 等未知字段 v0.1 视而不见（容忍未知字段，
/// R15.A.2 forward-compatible —— fromJson 只取已知字段，不报错）。
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part '../generated/models/bootstrap_payload.freezed.dart';
part '../generated/models/bootstrap_payload.g.dart';

@freezed
abstract class BootstrapPayload with _$BootstrapPayload {
  const factory BootstrapPayload({
    @JsonKey(name: 'api_endpoints') @Default(<String>[]) List<String> apiEndpoints,
    @JsonKey(name: 'subscription_endpoints')
    @Default(<String>[]) List<String> subscriptionEndpoints,
  }) = _BootstrapPayload;

  const BootstrapPayload._();

  factory BootstrapPayload.fromJson(Map<String, dynamic> json) =>
      _$BootstrapPayloadFromJson(json);

  /// 有效性（R15.B.7：两个 endpoint 列表各 ≥1）。
  bool get isValid =>
      apiEndpoints.isNotEmpty && subscriptionEndpoints.isNotEmpty;

  /// 返回 endpoint 规范化后的副本（解密成功后统一调，下游竞速/SDK 拿到干净 baseUrl）。
  ///
  /// 规范化规则（[normalizeEndpoint]）：trim 空白 + 去末尾所有 `/`（避免 `/omo/` + `/api/v1`
  /// 拼出 `/omo//api/v1` 双斜杠）+ 丢弃空串。保留 scheme `://`、保留路径前缀（`/omo`）。
  BootstrapPayload normalized() => BootstrapPayload(
        apiEndpoints: _normalizeList(apiEndpoints),
        subscriptionEndpoints: _normalizeList(subscriptionEndpoints),
      );

  static List<String> _normalizeList(List<String> urls) => urls
      .map(normalizeEndpoint)
      .where((e) => e.isNotEmpty)
      .toList(growable: false);

  /// 单个 endpoint 规范化：trim + 去末尾斜杠（保留 `scheme://`）。
  ///
  /// 例：`https://h/omo/ ` → `https://h/omo`；`https://h/` → `https://h`；`https://` 原样
  /// （只剩 scheme 不动，避免误删）。
  static String normalizeEndpoint(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    // 找 scheme 分隔符 `://` 之后的部分，只对其后的 trailing slash 处理。
    final schemeIdx = s.indexOf('://');
    final base = schemeIdx >= 0 ? schemeIdx + 3 : 0;
    // 去掉末尾所有 `/`，但不越过 scheme（base 之后至少留空）。
    var end = s.length;
    while (end > base && s.codeUnitAt(end - 1) == 0x2F /* '/' */) {
      end--;
    }
    return s.substring(0, end);
  }
}
