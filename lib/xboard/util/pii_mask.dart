/// PII 脱敏算法（数据一致性总章 § D / ε4 / D11，v0.1 锁定）。
///
/// **用途**：① 账号卡 UI 显示掩码（识别归属即可，不暴露完整 PII）；② R6 离线缓存写盘前
/// 脱敏（email/uuid 不明文落 SharedPreferences，NFR-3）。
///
/// **缓存读取语义**：UI 离线态展示 mask 后的值即可（不反向解码）；在线态优先 SDK 实时明文
/// （仅内存 + UI 渲染，不落盘）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// email 脱敏：`abc@example.com` → `ab***@example.com`（前 2 + *** + 域名）。
///
/// 本地部分 < 2 字符或格式异常 → `***@<域名或***>`（保守不泄露）。
String maskEmail(String email) {
  final parts = email.split('@');
  if (parts.length != 2 || parts[0].length < 2) {
    return '***@${parts.length > 1 ? parts[1] : '***'}';
  }
  return '${parts[0].substring(0, 2)}***@${parts[1]}';
}

/// uuid 脱敏：仅保留前 8 位 + `***`（与 R7 拼订阅 url 同源）。长度 < 8 → `***`。
String maskUuid(String uuid) {
  if (uuid.length < 8) return '***';
  return '${uuid.substring(0, 8)}***';
}

/// 由鉴权 token 派生 userIdHash（缓存 key 前缀 / 账号注销 mailto 用）。
///
/// sha256(token) 的十六进制前 [length] 位（默认 8）；token 为空返 `'anon'`。
/// **绝不**把原始 token / 完整 email 落盘或入 mailto（用 hash 反查）。
String userIdHashFromToken(String? token, {int length = 8}) {
  if (token == null || token.isEmpty) return 'anon';
  final digest = sha256.convert(utf8.encode(token));
  return digest.toString().substring(0, length);
}
