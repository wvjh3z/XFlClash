/// 测试用 Bootstrap 加密 helper —— 生成合法 envelope 密文供解密测试。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/models/bootstrap_envelope.dart';

/// 32 字节测试 AES key。
final List<int> testAesKey = List<int>.generate(32, (i) => (i * 7 + 3) % 256);

/// 用 [key]（默认 testAesKey）+ 正确 AAD 加密 [payloadJson]，返回 base64(nonce||cipher||tag)。
Future<String> encryptPayload(
  Map<String, dynamic> payloadJson, {
  List<int>? key,
  String aad = kBootstrapAad,
}) async {
  final algo = AesGcm.with256bits();
  final secretKey = SecretKey(key ?? testAesKey);
  final nonce = algo.newNonce();
  final box = await algo.encrypt(
    utf8.encode(jsonEncode(payloadJson)),
    secretKey: secretKey,
    nonce: nonce,
    aad: utf8.encode(aad),
  );
  final packed = Uint8List.fromList([
    ...nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
  return base64Encode(packed);
}

/// 构造合法 envelope（schemaVersion=1 + 加密 payload）。
Future<BootstrapEnvelope> validEnvelope({
  List<String> api = const ['https://api1.example.com'],
  List<String> sub = const ['https://sub1.example.com'],
  List<int>? key,
  String aad = kBootstrapAad,
  int schemaVersion = 1,
}) async {
  final enc = await encryptPayload(
    {'api_endpoints': api, 'subscription_endpoints': sub},
    key: key,
    aad: aad,
  );
  return BootstrapEnvelope(schemaVersion: schemaVersion, encrypted: enc);
}
