/// Bootstrap AES-256-GCM 解密 + 校验（R15.A / D58 / D59，cryptography ^2.7.0）。
///
/// 三来源（远端镜像 / 本地缓存 / 出厂 fallback）envelope 同形态，统一经此解密。
/// **永不抛**（Property 1）：任何失败（版本/密钥/tag/AAD/payload 校验/未配置 key）→ 返 null +
/// 归类对应 [BootstrapDecryptFailure]（DD-23 Sentry tag 用），调用方视该来源不可用。
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../config/bootstrap_constants.dart';
import '../models/bootstrap_envelope.dart';
import '../models/bootstrap_payload.dart';

/// 解密失败分类（DD-23 decryption_failure tag 的 5 种路径 + 无 key）。
enum BootstrapDecryptFailure {
  /// schema_version < 1（版本不兼容）。
  schemaIncompatible,

  /// 密文长度非法（< nonce+tag）。
  malformedCiphertext,

  /// GCM 解密失败（密钥错 / tag 错 / AAD 错，三者无法区分，统一归此）。
  decryptError,

  /// 解密成功但 JSON parse 失败。
  payloadParseError,

  /// payload 校验失败（api/subscription endpoints 任一为空）。
  payloadEmpty,

  /// flavor 未配置 AES key（编译期未注入）。
  noKey,
}

/// 解密结果（payload 或失败原因，二选一）。
class BootstrapDecryptResult {
  const BootstrapDecryptResult._(this.payload, this.failure);

  factory BootstrapDecryptResult.success(BootstrapPayload payload) =>
      BootstrapDecryptResult._(payload, null);
  factory BootstrapDecryptResult.failure(BootstrapDecryptFailure failure) =>
      BootstrapDecryptResult._(null, failure);

  final BootstrapPayload? payload;
  final BootstrapDecryptFailure? failure;

  bool get isSuccess => payload != null;
}

/// Bootstrap 解密器（注入 AES key 便于测试）。
class BootstrapDecryptor {
  BootstrapDecryptor({required List<int>? aesKey}) : _aesKey = aesKey;

  final List<int>? _aesKey;
  final _algo = AesGcm.with256bits();

  /// 解密 + 校验 envelope。永不抛；失败返 [BootstrapDecryptResult.failure]。
  Future<BootstrapDecryptResult> decryptAndValidate(BootstrapEnvelope env) async {
    final key = _aesKey;
    if (key == null || key.length != 32) {
      return BootstrapDecryptResult.failure(BootstrapDecryptFailure.noKey);
    }
    if (env.schemaVersion < 1) {
      return BootstrapDecryptResult.failure(
          BootstrapDecryptFailure.schemaIncompatible);
    }

    List<int> bytes;
    try {
      bytes = base64Decode(env.encrypted);
    } catch (_) {
      return BootstrapDecryptResult.failure(
          BootstrapDecryptFailure.malformedCiphertext);
    }
    // 布局：nonce(12) || ciphertext || tag(16)。
    if (bytes.length < 12 + 16) {
      return BootstrapDecryptResult.failure(
          BootstrapDecryptFailure.malformedCiphertext);
    }

    List<int> clear;
    try {
      final nonce = bytes.sublist(0, 12);
      final mac = bytes.sublist(bytes.length - 16);
      final cipher = bytes.sublist(12, bytes.length - 16);
      clear = await _algo.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
        aad: utf8.encode(kBootstrapAad),
      );
    } catch (_) {
      // 密钥/tag/AAD 不符（GCM 认证失败）。
      return BootstrapDecryptResult.failure(BootstrapDecryptFailure.decryptError);
    }

    BootstrapPayload payload;
    try {
      payload = BootstrapPayload.fromJson(
          jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
    } catch (_) {
      return BootstrapDecryptResult.failure(
          BootstrapDecryptFailure.payloadParseError);
    }

    if (!payload.isValid) {
      return BootstrapDecryptResult.failure(BootstrapDecryptFailure.payloadEmpty);
    }
    return BootstrapDecryptResult.success(payload);
  }
}
