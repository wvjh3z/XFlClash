/// 测试期 `TokenStorage` 实现 —— 内存版（`MemoryTokenStorage` 同款，D63 / F81）。
///
/// **关联**：design §C / 决策 #9 / D63（测试环境强制 MemoryTokenStorage，
/// Linux headless 无 D-Bus session bus，secure_storage 会抛 PlatformException）。
///
/// raw token 语义（F277）：存的是不带 `'Bearer '` 前缀的 raw token；Bearer 由
/// SDK AuthInterceptor 请求时拼。本 fake 不做任何前缀处理，原样存取。
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';

/// 进程内内存 token 存储，测试用。无平台依赖、无持久化。
class FakeTokenStorage implements TokenStorage {
  FakeTokenStorage({String? initialToken}) : _token = initialToken;

  String? _token;

  /// 测试断言用：当前是否存有 token。
  bool get hasToken => _token != null;

  @override
  Future<void> get ready async {}

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> writeToken(String rawToken) async => _token = rawToken;

  @override
  Future<void> deleteToken() async => _token = null;
}
