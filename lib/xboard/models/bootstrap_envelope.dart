/// Bootstrap 外层加密信封（R15 / D58）。
///
/// 远端镜像 / 本地缓存 / 出厂 fallback **三来源同形态**：明文 `schemaVersion`（解密前快速
/// 识别版本）+ base64 密文 `encrypted`（`nonce(12B) || ciphertext || tag(16B)`，AES-256-GCM）。
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part '../generated/models/bootstrap_envelope.freezed.dart';
part '../generated/models/bootstrap_envelope.g.dart';

@freezed
abstract class BootstrapEnvelope with _$BootstrapEnvelope {
  const factory BootstrapEnvelope({
    @JsonKey(name: 'schema_version') required int schemaVersion,
    required String encrypted, // base64(nonce(12B) || ciphertext || tag(16B))
  }) = _BootstrapEnvelope;

  factory BootstrapEnvelope.fromJson(Map<String, dynamic> json) =>
      _$BootstrapEnvelopeFromJson(json);
}
