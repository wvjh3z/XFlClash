/// Bootstrap AES-256-GCM 解密 + 校验（R15.A / D58 / D59，cryptography ^2.7.0）。
///
/// 三来源（远端镜像 / 本地缓存 / 出厂 fallback）envelope 同形态，统一经此解密。
/// **永不抛**（Property 1）：任何失败（版本/密钥/tag/AAD/payload 校验/未配置 key）→ 返 null +
/// 归类对应 [BootstrapDecryptFailure]（DD-23 Sentry tag 用），调用方视该来源不可用。
library;

import 'dart:convert';
import 'dart:typed_data';

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

/// DD-23 `bootstrap.decryption_failure` tag 值映射（5.7.3：5 种失败路径各异 + noKey）。
///
/// 纯映射（无副作用），便于单测穷举；编排层失败时调
/// `SentryBootstrap.tagBootstrap(decryptionFailure: failure.tagValue)`。
extension BootstrapDecryptFailureTag on BootstrapDecryptFailure {
  String get tagValue => switch (this) {
        BootstrapDecryptFailure.schemaIncompatible => 'schema_incompatible',
        BootstrapDecryptFailure.malformedCiphertext => 'malformed_ciphertext',
        BootstrapDecryptFailure.decryptError => 'decrypt_error',
        BootstrapDecryptFailure.payloadParseError => 'payload_parse_error',
        BootstrapDecryptFailure.payloadEmpty => 'payload_empty',
        BootstrapDecryptFailure.noKey => 'no_key',
      };
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

/// 原始字节解密结果（R4.1 加密订阅复用 AES-GCM 核心，明文非 endpoint JSON 而是任意 bytes）。
///
/// 与 [BootstrapDecryptResult] 区分：后者解出 + 校验 [BootstrapPayload]（endpoint 列表）；
/// 本类只解出明文字节（如 ClashMeta YAML），不做 payload 语义校验，由调用方处理。
class RawDecryptResult {
  const RawDecryptResult._(this.clearBytes, this.failure);

  factory RawDecryptResult.success(Uint8List clearBytes) =>
      RawDecryptResult._(clearBytes, null);
  factory RawDecryptResult.failure(BootstrapDecryptFailure failure) =>
      RawDecryptResult._(null, failure);

  final Uint8List? clearBytes;
  final BootstrapDecryptFailure? failure;

  bool get isSuccess => clearBytes != null;
}

/// Bootstrap 解密器（注入 AES key 便于测试）。
class BootstrapDecryptor {
  BootstrapDecryptor({required List<int>? aesKey}) : _aesKey = aesKey;

  final List<int>? _aesKey;
  final _algo = AesGcm.with256bits();

  /// 解密 + 校验 envelope。永不抛；失败返 [BootstrapDecryptResult.failure]。
  Future<BootstrapDecryptResult> decryptAndValidate(BootstrapEnvelope env) async {
    if (env.schemaVersion < 1) {
      return BootstrapDecryptResult.failure(
          BootstrapDecryptFailure.schemaIncompatible);
    }
    // AES-GCM 核心解密（AAD = bootstrap 用途）。
    final raw = await decryptCiphertext(
      base64Cipher: env.encrypted,
      aad: kBootstrapAad,
    );
    if (!raw.isSuccess) {
      return BootstrapDecryptResult.failure(raw.failure!);
    }

    BootstrapPayload payload;
    try {
      payload = BootstrapPayload.fromJson(
          jsonDecode(utf8.decode(raw.clearBytes!)) as Map<String, dynamic>);
    } catch (_) {
      return BootstrapDecryptResult.failure(
          BootstrapDecryptFailure.payloadParseError);
    }

    // endpoint 规范化（去末尾斜杠等，避免下游拼接出 `/omo//api/v1` 双斜杠）。
    payload = payload.normalized();

    if (!payload.isValid) {
      return BootstrapDecryptResult.failure(BootstrapDecryptFailure.payloadEmpty);
    }
    return BootstrapDecryptResult.success(payload);
  }

  /// AES-256-GCM 解密核心（R4.1 复用入口）：解 base64 → 拆 `nonce(12)‖cipher‖tag(16)` → GCM 解密。
  ///
  /// 密码学约定与 bootstrap 完全一致（nonce 12B 拼前 / tag 16B 拼后），仅 [aad] 由调用方指定
  /// （bootstrap 用 [kBootstrapAad]，加密订阅用 [kEncryptedSubscriptionAad]）。永不抛——失败归
  /// [BootstrapDecryptFailure]（noKey / malformedCiphertext / decryptError 三种适用）。
  Future<RawDecryptResult> decryptCiphertext({
    required String base64Cipher,
    required String aad,
  }) async {
    final key = _aesKey;
    if (key == null || key.length != 32) {
      return RawDecryptResult.failure(BootstrapDecryptFailure.noKey);
    }

    List<int> bytes;
    try {
      bytes = base64Decode(base64Cipher.trim());
    } catch (_) {
      return RawDecryptResult.failure(BootstrapDecryptFailure.malformedCiphertext);
    }
    // 布局：nonce(12) || ciphertext || tag(16)。
    if (bytes.length < 12 + 16) {
      return RawDecryptResult.failure(BootstrapDecryptFailure.malformedCiphertext);
    }

    try {
      final nonce = bytes.sublist(0, 12);
      final mac = bytes.sublist(bytes.length - 16);
      final cipher = bytes.sublist(12, bytes.length - 16);
      final clear = await _algo.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
        aad: utf8.encode(aad),
      );
      return RawDecryptResult.success(Uint8List.fromList(clear));
    } catch (_) {
      // 密钥/tag/AAD 不符（GCM 认证失败）。
      return RawDecryptResult.failure(BootstrapDecryptFailure.decryptError);
    }
  }
}
