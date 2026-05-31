/// W5.1.9 — BootstrapDecryptor：合法密文 PASS / nonce·tag·AAD·schema·empty 全归 failure。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/bootstrap_envelope.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';

import '_bootstrap_crypto_helper.dart';

void main() {
  late BootstrapDecryptor decryptor;
  setUp(() => decryptor = BootstrapDecryptor(aesKey: testAesKey));

  test('合法密文 → success + 正确 endpoints', () async {
    final env = await validEnvelope(
      api: ['https://a.com'],
      sub: ['https://s.com'],
    );
    final r = await decryptor.decryptAndValidate(env);
    expect(r.isSuccess, isTrue);
    expect(r.payload!.apiEndpoints, ['https://a.com']);
    expect(r.payload!.subscriptionEndpoints, ['https://s.com']);
  });

  test('schemaVersion < 1 → schemaIncompatible', () async {
    final env = await validEnvelope(schemaVersion: 0);
    final r = await decryptor.decryptAndValidate(env);
    expect(r.failure, BootstrapDecryptFailure.schemaIncompatible);
  });

  test('错误 key → decryptError', () async {
    final env = await validEnvelope(); // testAesKey 加密
    final wrong = BootstrapDecryptor(
        aesKey: List<int>.generate(32, (i) => 255 - i));
    final r = await wrong.decryptAndValidate(env);
    expect(r.failure, BootstrapDecryptFailure.decryptError);
  });

  test('错误 AAD → decryptError', () async {
    final env = await validEnvelope(aad: 'wrong-aad');
    final r = await decryptor.decryptAndValidate(env);
    expect(r.failure, BootstrapDecryptFailure.decryptError);
  });

  test('篡改密文（tag 不符）→ decryptError', () async {
    final env = await validEnvelope();
    // 解码 → 翻转 ciphertext 中间一个字节 → 重新编码（保证长度不变 + tag 校验必失败）。
    final bytes = base64Decode(env.encrypted);
    final mid = bytes.length ~/ 2;
    bytes[mid] = bytes[mid] ^ 0xFF;
    final tampered = base64Encode(bytes);
    final r = await decryptor.decryptAndValidate(
        BootstrapEnvelope(schemaVersion: 1, encrypted: tampered));
    expect(r.failure, BootstrapDecryptFailure.decryptError);
  });

  test('非法 base64 / 过短 → malformedCiphertext', () async {
    final r = await decryptor.decryptAndValidate(
        const BootstrapEnvelope(schemaVersion: 1, encrypted: 'QUJD')); // "ABC" 3B < 28
    expect(r.failure, BootstrapDecryptFailure.malformedCiphertext);
  });

  test('payload 空 endpoints → payloadEmpty', () async {
    final env = await validEnvelope(api: [], sub: []);
    final r = await decryptor.decryptAndValidate(env);
    expect(r.failure, BootstrapDecryptFailure.payloadEmpty);
  });

  test('未配置 key → noKey', () async {
    final env = await validEnvelope();
    final noKey = BootstrapDecryptor(aesKey: null);
    final r = await noKey.decryptAndValidate(env);
    expect(r.failure, BootstrapDecryptFailure.noKey);
  });

  test('key 长度非 32 → noKey', () async {
    final env = await validEnvelope();
    final shortKey = BootstrapDecryptor(aesKey: [1, 2, 3]);
    final r = await shortKey.decryptAndValidate(env);
    expect(r.failure, BootstrapDecryptFailure.noKey);
  });
}
