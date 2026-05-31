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
}
