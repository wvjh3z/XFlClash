/// W3.1.6 — SecureStorageTokenStorage + AES 降级单测。
///
/// 重点测 AES-256-GCM SharedPreferences fallback（ζ1 Linux 降级路径）的加解密 round-trip +
/// fail-safe（key 变更 → 视作无 token）+ token 明文不落盘（NFR-3）。
///
/// secure_storage 真机路径 + 探测降级在真机/CI 集成测，单测聚焦可测的 AES fallback 逻辑。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/sdk/secure_storage_token_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List key32([int seed = 1]) =>
      Uint8List.fromList(List.generate(32, (i) => (i + seed) % 256));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AesEncryptedSharedPrefsTokenStorage（ζ1 降级）', () {
    test('write → read round-trip', () async {
      final s = AesEncryptedSharedPrefsTokenStorage(aesKey: key32());
      await s.ready;
      expect(await s.readToken(), isNull);

      await s.writeToken('Bearer raw-token-123');
      expect(await s.readToken(), 'Bearer raw-token-123');

      await s.deleteToken();
      expect(await s.readToken(), isNull);
    });

    test('token 明文不落 SharedPreferences（NFR-3）', () async {
      final s = AesEncryptedSharedPrefsTokenStorage(aesKey: key32());
      await s.writeToken('SECRET_TOKEN_PLAINTEXT');
      final prefs = await SharedPreferences.getInstance();
      // 遍历所有存的值，确认无明文
      for (final k in prefs.getKeys()) {
        final v = prefs.get(k);
        if (v is String) {
          expect(v.contains('SECRET_TOKEN_PLAINTEXT'), isFalse,
              reason: 'token 明文落盘了：$k');
          // 存的应是 base64 密文
          expect(() => base64Decode(v), returnsNormally);
        }
      }
    });

    test('key 变更 → 解密失败 fail-safe 返 null（DD-22）', () async {
      final s1 = AesEncryptedSharedPrefsTokenStorage(aesKey: key32(1));
      await s1.writeToken('token-with-key-1');

      // 同一份 SharedPreferences，换 key 读 → 解密失败 → null（不抛）
      final s2 = AesEncryptedSharedPrefsTokenStorage(aesKey: key32(99));
      expect(await s2.readToken(), isNull);
    });

    test('非 32 字节 key → assert', () {
      expect(
        () => AesEncryptedSharedPrefsTokenStorage(
            aesKey: Uint8List.fromList([1, 2, 3])),
        throwsA(isA<AssertionError>()),
      );
    });

    test('每次 write 用新 nonce（同 token 两次密文不同）', () async {
      final s = AesEncryptedSharedPrefsTokenStorage(aesKey: key32());
      await s.writeToken('same-token');
      final prefs = await SharedPreferences.getInstance();
      final c1 = prefs.getString('${kXbAccessTokenKey}_aesgcm');
      await s.writeToken('same-token');
      final c2 = prefs.getString('${kXbAccessTokenKey}_aesgcm');
      expect(c1, isNot(equals(c2)), reason: 'nonce 应每次不同');
      // 但都能解回同值
      expect(await s.readToken(), 'same-token');
    });
  });
}
