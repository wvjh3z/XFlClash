/// Xboard TokenStorage：系统安全存储优先，故障时使用既有 AES-GCM 回退。
/// 有效后端与凭据引用以单个持久化记录提交；退出记录阻止旧凭据复活。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../storage/brand_paths.dart';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show TokenStorage;
import 'package:shared_preferences/shared_preferences.dart';

/// 升级前的凭据键。macOS旧键跨品牌无归属，不自动恢复。
const String kXbAccessTokenKey = 'xb_access_token_v1';

/// 生产存储工厂，所有调用通过同一个恢复与提交保护实例。
abstract final class SecureStorageTokenStorage {
  /// 当前macOS采用ad-hoc分发，不能依赖数据保护钥匙串的签名访问组。
  /// 此选项是锁定的9.2.4/3.1.3实际读取的键，不改变其他平台选项。
  static const defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      migrateOnAlgorithmChange: false,
      resetOnError: false,
    ),
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static Future<TokenStorage> create({
    FlutterSecureStorage? storage,
    required Uint8List fallbackAesKey,
    String namespace = 'default',
    void Function()? onDegraded,
    Duration operationTimeout = const Duration(seconds: 5),
    bool? allowUnscopedLegacy,
  }) async {
    final result = _RecoveringTokenStorage(
      storage ?? defaultStorage,
      fallbackAesKey,
      namespace,
      onDegraded,
      operationTimeout,
      allowUnscopedLegacy ?? !isolatedDesktopBrand,
    );
    // ready/read/write触发同一初始化；失败保留此实例，下一次操作可重试。
    // 不能因初始化失败返回null，让SDK意外选择默认明文SharedPreferences。
    return result;
  }
}

/// 配置无效时仍注入SDK，避免null导致默认明文存储。登录可明确失败，游客可运行。
class UnavailableTokenStorage implements TokenStorage {
  const UnavailableTokenStorage();
  @override
  Future<void> get ready => Future.value();
  @override
  Future<String?> readToken() async => null;
  @override
  Future<void> writeToken(String token) async =>
      throw StateError('Token storage configuration unavailable');
  @override
  Future<void> deleteToken() async =>
      throw StateError('Token storage configuration unavailable');
}

class _RecoveringTokenStorage implements TokenStorage {
  _RecoveringTokenStorage(
    this._secure,
    Uint8List key,
    String namespace,
    this._onDegraded,
    this._timeout,
    this._allowUnscopedLegacy,
  ) : _prefix = '${kXbAccessTokenKey}_${Uri.encodeComponent(namespace)}',
      _cipher = AesEncryptedSharedPrefsTokenStorage(aesKey: key);

  final FlutterSecureStorage _secure;
  final AesEncryptedSharedPrefsTokenStorage _cipher;
  final String _prefix;
  final void Function()? _onDegraded;
  final Duration _timeout;
  final bool _allowUnscopedLegacy;
  final _random = Random.secure();
  Future<void> _pending = Future.value();
  bool _initialized = false;
  String? _cachedKey;
  String? _cachedToken;
  @override
  Future<void> get ready => _serialized(() async {});
  bool _reportedDegraded = false;
  String get _recordKey => '${_prefix}_record_v2';
  String _uniqueKey() =>
      '${_prefix}_${base64UrlEncode(List<int>.generate(18, (_) => _random.nextInt(256)))}';

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _pending.then((_) async {
      if (!_initialized) {
        await _initialize();
        _initialized = true;
      }
      return action();
    });
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _degraded() {
    if (_reportedDegraded) return;
    _reportedDegraded = true;
    _onDegraded?.call();
  }

  Future<Map<String, dynamic>?> _record() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // setString失败时可能已经改了插件的Dart缓存。
    final raw = prefs.getString(_recordKey);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw) as Map<String, dynamic>;
      if (value['version'] != 2 ||
          !['secure', 'fallback'].contains(value['backend']) ||
          (value['key'] != null &&
              (value['key'] is! String ||
                  !(value['key'] as String).startsWith('${_prefix}_'))) ||
          (value['value'] != null && value['value'] is! String)) {
        throw const FormatException('Invalid token storage record');
      }
      return value;
    } catch (_) {
      // 已有记录损坏也不能再尝试旧键，否则退出/换号可能恢复旧账号。
      await _commit('fallback');
      _degraded();
      return {'backend': 'fallback'};
    }
  }

  Future<void> _commit(String backend, {String? key, String? token}) async {
    final raw = jsonEncode({
      'version': 2,
      'backend': backend,
      'key': ?key,
      if (token != null) 'value': await _cipher.encrypt(token),
    });
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_recordKey, raw)) {
      await prefs.reload();
      throw StateError('Token storage commit rejected');
    }
    await prefs.reload();
    if (prefs.getString(_recordKey) != raw) {
      throw StateError('Token storage commit verification failed');
    }
    if (key == null) {
      _cachedKey = null;
      _cachedToken = null;
    }
  }

  Future<void> _deleteSecure(String? key) async {
    if (key == null) return;
    await _secure.delete(key: key).timeout(_timeout);
    if (await _secure.read(key: key).timeout(_timeout) != null) {
      throw StateError('Token storage delete verification failed');
    }
  }

  Future<void> _cleanup(String? key) async {
    try {
      await _deleteSecure(key);
    } catch (_) {
      // 已提交记录不再引用此键；残留数据不能用于恢复会话。
      // 原生钥匙串拒绝删除时，不能声称物理凭据已清除。
    }
  }

  Future<void> _verifiedWrite(String key, String token) async {
    final operation = () async {
      await _secure.write(key: key, value: token);
      if (await _secure.read(key: key) != token) {
        throw StateError('Token storage write verification failed');
      }
    }();
    try {
      await operation.timeout(_timeout);
    } catch (_) {
      // timeout不会取消原生写入。每次使用独立键，迟到写入永不覆盖有效Token；
      // 等原操作结束再做尽力清理，不阻塞回退或后续退出。
      unawaited(
        operation.then(
          (_) => _cleanup(key),
          onError: (Object _, StackTrace _) => _cleanup(key),
        ),
      );
      rethrow;
    }
  }

  Future<void> _probe() async {
    final key = _uniqueKey();
    try {
      await _verifiedWrite(key, 'xboard-storage-probe');
      await _deleteSecure(key);
    } catch (_) {
      unawaited(_cleanup(key));
      rethrow;
    }
  }

  Future<void> _initialize() async {
    final record = await _record();
    if (record != null) {
      if (record['backend'] == 'fallback') _degraded();
      return; // 持久化的后端选择优先；不因系统恢复重新读旧安全存储。
    }
    if (!_allowUnscopedLegacy) {
      // A shared historical key has no brand ownership. Start a new backend;
      // positively attributed encrypted records were migrated before SDK init.
      try {
        await _probe();
        await _commit('secure');
      } catch (_) {
        await _commit('fallback');
        _degraded();
      }
      return;
    }
    // 兼容此前Linux等平台的加密回退，成功迁移前不删除旧密文。
    final preferences = await SharedPreferences.getInstance();
    final legacyCiphertext = preferences.getString(
      AesEncryptedSharedPrefsTokenStorage._prefsKey,
    );
    if (legacyCiphertext != null) {
      String? previousFallback;
      try {
        previousFallback = await _cipher.decrypt(legacyCiphertext);
      } catch (_) {
        // 密文可能损坏或属于共用旧偏好域的另一品牌。不删除不属于本key的数据，
        // 也不继续读取更老的安全存储账号；本品牌建立空记录后重新登录。
      }
      await _commit('fallback', token: previousFallback);
      _degraded();
      return;
    }
    String? previous;
    try {
      // macOS历史默认service/key无品牌归属，且来自另一类钥匙串，不自动迁移。
      if (defaultTargetPlatform != TargetPlatform.macOS) {
        previous = await _secure.read(key: kXbAccessTokenKey).timeout(_timeout);
      }
      await _probe();
    } catch (_) {
      await _commit('fallback', token: previous);
      _degraded();
      return;
    }
    if (previous == null) {
      await _commit('secure');
    } else {
      await _write(previous);
    }
  }

  @override
  Future<String?> readToken() => _serialized(() async {
    final record = await _record();
    if (record == null) return null;
    if (record['backend'] == 'fallback') {
      final value = record['value'] as String?;
      if (value == null) return null;
      try {
        return await _cipher.decrypt(value);
      } catch (_) {
        await _commit('fallback');
        return null;
      }
    }
    final key = record['key'] as String?;
    if (key == null) return null;
    try {
      final token = await _secure.read(key: key).timeout(_timeout);
      if (token == null) throw StateError('Token storage item missing');
      _cachedKey = key;
      _cachedToken = token;
      return token;
    } catch (_) {
      // 仅迁移当前记录对应的已验证凭据，保持运行中SDK会话一致。
      // 冷启动没有可信副本时退为游客，下一次登录可以使用回退。
      final recovered = _cachedKey == key ? _cachedToken : null;
      await _commit('fallback', token: recovered);
      _degraded();
      unawaited(_cleanup(key));
      return recovered;
    }
  });

  Future<void> _write(String token) async {
    final previous = await _record();
    if (previous?['backend'] == 'fallback') {
      await _commit('fallback', token: token);
      return;
    }
    final key = _uniqueKey();
    try {
      await _verifiedWrite(key, token);
    } catch (_) {
      await _commit('fallback', token: token);
      _degraded();
      unawaited(_cleanup(previous?['key'] as String?));
      return;
    }
    try {
      await _commit('secure', key: key);
      _cachedKey = key;
      _cachedToken = token;
    } catch (_) {
      unawaited(_cleanup(key));
      rethrow;
    }
    unawaited(_cleanup(previous?['key'] as String?));
  }

  @override
  Future<void> writeToken(String token) => _serialized(() => _write(token));

  @override
  Future<void> deleteToken() => _serialized(() async {
    final previous = await _record();
    // 先提交空会话，再删除凭据。原生删除失败/超时也不会在重启时恢复旧账号。
    await _commit(previous?['backend'] == 'fallback' ? 'fallback' : 'secure');
    unawaited(_cleanup(previous?['key'] as String?));
    if (_allowUnscopedLegacy && defaultTargetPlatform != TargetPlatform.macOS) {
      unawaited(_cleanup(kXbAccessTokenKey));
    }
    // 旧版本AES数据已不再权威，清理失败不能让已提交的退出变成未退出。
    if (_allowUnscopedLegacy) unawaited(_cleanupLegacyFallback());
  });

  Future<void> _cleanupLegacyFallback() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(
        AesEncryptedSharedPrefsTokenStorage._prefsKey,
      );
      if (raw == null) return;
      await _cipher.decrypt(raw); // 仅清理当前品牌能够验证的旧密文。
      await _cipher.deleteToken();
    } catch (_) {}
  }
}

/// 既有AES-GCM密文编解码与旧回退记录迁移适配。
///
/// key 使用 flavor BootstrapAesKey（32 字节），其保护不等同系统钥匙串；
/// token 明文绝不落 SharedPreferences（NFR-3）—— 存 `base64(nonce||ciphertext||mac)`。
class AesEncryptedSharedPrefsTokenStorage implements TokenStorage {
  AesEncryptedSharedPrefsTokenStorage({required Uint8List aesKey})
    : assert(aesKey.length == 32, 'AES-256 key 必须 32 字节'),
      _key = Uint8List.fromList(aesKey) {
    if (aesKey.length != 32) throw ArgumentError('AES-256 requires 32 bytes');
  }

  final Uint8List _key;
  final _algo = AesGcm.with256bits();
  static const _prefsKey = '${kXbAccessTokenKey}_aesgcm';

  @override
  Future<String?> readToken() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return null;
    try {
      return await decrypt(raw);
    } catch (_) {
      // 解密失败（key 变更 / 数据损坏）→ 视作无 token（DD-22 fail-safe）
      if (!await prefs.remove(_prefsKey)) {
        throw StateError('Token storage removal rejected');
      }
      return null;
    }
  }

  Future<String> encrypt(String token) async {
    final box = await _algo.encrypt(
      utf8.encode(token),
      secretKey: SecretKey(_key),
      nonce: _algo.newNonce(),
    );
    return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<String> decrypt(String raw) async {
    final bytes = base64Decode(raw);
    final box = SecretBox(
      bytes.sublist(12, bytes.length - 16),
      nonce: bytes.sublist(0, 12),
      mac: Mac(bytes.sublist(bytes.length - 16)),
    );
    return utf8.decode(await _algo.decrypt(box, secretKey: SecretKey(_key)));
  }

  @override
  Future<void> writeToken(String t) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = await encrypt(t);
    if (!await prefs.setString(_prefsKey, raw)) {
      await prefs.reload();
      throw StateError('Token storage write rejected');
    }
    await prefs.reload();
    if (prefs.getString(_prefsKey) != raw) {
      throw StateError('Token storage write verification failed');
    }
  }

  @override
  Future<void> deleteToken() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_prefsKey)) {
      await prefs.reload();
      throw StateError('Token storage removal rejected');
    }
    await prefs.reload();
    if (prefs.containsKey(_prefsKey)) {
      throw StateError('Token storage removal verification failed');
    }
  }

  @override
  Future<void> get ready => Future.value();
}
