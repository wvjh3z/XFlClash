/// Token 存储实现（NFR-3 / D28 / F404 / ζ1）。
///
/// FlClash 主仓 0 处 token 存储（F404）；客户端实现 SDK `TokenStorage` 接口注入 secure_storage。
///
/// **ζ1 Linux 降级**：Linux 桌面 secure_storage 后端是 libsecret + D-Bus；headless 容器 / 缺
/// gnome-keyring 时 `read/write` 抛 `PlatformException`。`SecureStorageTokenStorage.create()`
/// 构造时探测，失败则降级到 [AesEncryptedSharedPrefsTokenStorage]（AES-256-GCM 加密
/// SharedPreferences）+ 上层显示降级 banner（建议安装 gnome-keyring）。
///
/// **测试环境（D63/F81）**：headless 无 D-Bus → bootstrap 走 `useMemoryStorage`（SDK 自带
/// MemoryTokenStorage），不实例化本类。本类仅 release/debug 真机用。
///
/// key 命名 DD-22 v1：`xb_access_token_v1`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show TokenStorage;
import 'package:shared_preferences/shared_preferences.dart';

/// token 存储 key（DD-22 v1）。
const String kXbAccessTokenKey = 'xb_access_token_v1';

/// 直接走 secure_storage 的 TokenStorage 实现（默认路径）。
class SecureStorageTokenStorage implements TokenStorage {
  SecureStorageTokenStorage({FlutterSecureStorage? storage})
      : _storage =
            storage ?? const FlutterSecureStorage(aOptions: _androidOptions);

  final FlutterSecureStorage _storage;

  /// θ-10：Android 强制 EncryptedSharedPreferences（AES-256，硬件 keystore 支持时入 TEE）。
  /// 配合 AndroidManifest `allowBackup=false`（W8.4.3）防卸载重装 / ADB backup 残留。
  static const AndroidOptions _androidOptions =
      AndroidOptions(encryptedSharedPreferences: true);

  /// 探测 secure_storage 是否可用（ζ1）；不可用返降级实现。
  ///
  /// 返回的 [TokenStorage] 要么是本类（secure_storage OK），要么是
  /// [AesEncryptedSharedPrefsTokenStorage]（Linux 降级）。[onDegraded] 在降级时回调
  /// （上层显示 banner）。
  static Future<TokenStorage> create({
    FlutterSecureStorage? storage,
    required Uint8List fallbackAesKey,
    void Function()? onDegraded,
  }) async {
    final s = storage ?? const FlutterSecureStorage(aOptions: _androidOptions);
    try {
      await s.read(key: '__xb_probe__'); // ζ1 探测
      return SecureStorageTokenStorage(storage: s);
    } on PlatformException {
      // ζ1：Linux headless / 缺 gnome-keyring → libsecret/D-Bus 不可用，降级 AES-SharedPrefs。
      onDegraded?.call();
      return AesEncryptedSharedPrefsTokenStorage(aesKey: fallbackAesKey);
    }
  }

  @override
  Future<String?> readToken() => _storage.read(key: kXbAccessTokenKey);

  @override
  Future<void> writeToken(String t) =>
      _storage.write(key: kXbAccessTokenKey, value: t);

  @override
  Future<void> deleteToken() => _storage.delete(key: kXbAccessTokenKey);

  @override
  Future<void> get ready => Future.value();
}

/// Linux 降级实现（ζ1）：AES-256-GCM 加密后存 SharedPreferences。
///
/// secure_storage 不可用时的兜底。key 由 flavor BootstrapAesKey 派生（32 字节）；
/// token 明文绝不落 SharedPreferences（NFR-3）—— 存 `base64(nonce||ciphertext||mac)`。
class AesEncryptedSharedPrefsTokenStorage implements TokenStorage {
  AesEncryptedSharedPrefsTokenStorage({required Uint8List aesKey})
      : assert(aesKey.length == 32, 'AES-256 key 必须 32 字节'),
        _key = aesKey;

  final Uint8List _key;
  final _algo = AesGcm.with256bits();
  static const _prefsKey = '${kXbAccessTokenKey}_aesgcm';

  @override
  Future<String?> readToken() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return null;
    try {
      final bytes = base64Decode(raw);
      // 布局：nonce(12) || ciphertext || mac(16)
      final nonce = bytes.sublist(0, 12);
      final mac = bytes.sublist(bytes.length - 16);
      final cipher = bytes.sublist(12, bytes.length - 16);
      final secretBox = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
      final clear = await _algo.decrypt(
        secretBox,
        secretKey: SecretKey(_key),
      );
      return utf8.decode(clear);
    } catch (_) {
      // 解密失败（key 变更 / 数据损坏）→ 视作无 token（DD-22 fail-safe）
      await prefs.remove(_prefsKey);
      return null;
    }
  }

  @override
  Future<void> writeToken(String t) async {
    final prefs = await SharedPreferences.getInstance();
    final nonce = _algo.newNonce();
    final box = await _algo.encrypt(
      utf8.encode(t),
      secretKey: SecretKey(_key),
      nonce: nonce,
    );
    final packed = Uint8List.fromList([
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    await prefs.setString(_prefsKey, base64Encode(packed));
  }

  @override
  Future<void> deleteToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  @override
  Future<void> get ready => Future.value();
}
