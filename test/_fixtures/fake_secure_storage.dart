/// 测试期 `FlutterSecureStorage` fake —— 内存 map + Linux 降级路径模拟（ζ1）。
///
/// **关联**：design §C / 跨平台矩阵 §A（ζ1 Linux secure_storage 降级）/ 已知风险表
/// 「Linux secure_storage 降级」。
///
/// 用途：
/// - 默认行为：进程内 `Map<String,String>`，read/write/delete/containsKey/deleteAll 全可用。
/// - `simulateLinuxFailure=true`：read/write 抛 `PlatformException`（模拟 headless 容器无
///   D-Bus session bus，libsecret status 0），用于测 ζ1 降级到 AesEncryptedSharedPrefs 兜底。
///
/// `extends Mock implements FlutterSecureStorage`：手写覆盖核心 5 方法提供真实内存语义，
/// 其余成员（options getter / 平台特定方法）由 mocktail noSuchMethod 兜底。
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';

class FakeSecureStorage extends Mock implements FlutterSecureStorage {
  FakeSecureStorage({this.simulateLinuxFailure = false});

  /// true 时 read/write 抛 PlatformException（ζ1 — Linux headless 无 D-Bus）。
  bool simulateLinuxFailure;

  final Map<String, String> _store = {};

  /// 测试断言用：底层存了几个 key。
  int get length => _store.length;

  PlatformException get _linuxFailure => PlatformException(
        code: 'Libsecret error',
        message: 'Failed to unlock the keyring (status 0) — no D-Bus session bus',
      );

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (simulateLinuxFailure) throw _linuxFailure;
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (simulateLinuxFailure) throw _linuxFailure;
    return _store[key];
  }

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (simulateLinuxFailure) throw _linuxFailure;
    return _store.containsKey(key);
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (simulateLinuxFailure) throw _linuxFailure;
    return Map.unmodifiable(_store);
  }
}
