/// validationFailed 字段级错误渲染（β-8 + θ-9 安全约束）。
///
/// XbBusiness(kind: validationFailed) 携带 `validationErrors: Map<String, List<String>>`
/// （Laravel 422）。本工具把它转成「字段 → 单条错误文案」供 form input 下方红字渲染 +
/// 滚动到首个出错字段。
///
/// **θ-9 安全约束**（design Security 表）：
/// - **白名单过滤**：field key 必须在预知白名单内，不在则丢弃（防后端/中间人塞任意 key 撑爆 UI）
/// - **单条 message 截断 200 字符**（防性能攻击 / 超长文案撑爆布局）
/// - 每字段只取 `value.first`（数组首条，UI 一次显示一条）
library;

import 'package:flutter/widgets.dart';

/// θ-9 单条 message 最大长度（超出截断）。
const int kXbValidationMessageMaxLen = 200;

/// v0.1 主路径字段白名单（θ-9）。不在此集合的 field key 一律丢弃。
const Set<String> kXbValidationFieldWhitelist = {
  'email',
  'password',
  'inviteCode',
  'emailVerifyCode',
  'planId',
  'period',
  'couponCode',
};

/// 把后端 `validationErrors` 过滤 + 归一为「字段 → 单条错误文案」。
///
/// - 丢弃白名单外字段（θ-9）
/// - 每字段取首条非空 message，截断至 [kXbValidationMessageMaxLen]
/// - 返回保持插入顺序（首个出错字段 = first key，供滚动定位）
Map<String, String> sanitizeValidationErrors(
  Map<String, List<String>>? raw, {
  Set<String> whitelist = kXbValidationFieldWhitelist,
}) {
  final result = <String, String>{};
  if (raw == null) return result;
  for (final entry in raw.entries) {
    if (!whitelist.contains(entry.key)) continue; // θ-9 白名单过滤
    final first = entry.value.where((m) => m.trim().isNotEmpty).cast<String?>().firstWhere(
          (m) => m != null,
          orElse: () => null,
        );
    if (first == null) continue;
    final truncated = first.length > kXbValidationMessageMaxLen
        ? first.substring(0, kXbValidationMessageMaxLen)
        : first;
    result[entry.key] = truncated;
  }
  return result;
}

/// 滚动到首个出错字段（design β-8 渲染规约）。
///
/// [fieldKeys] = 各 form input 的 GlobalKey 映射；[errors] = sanitize 后的字段错误。
/// 找首个出错字段对应的 context → `Scrollable.ensureVisible`。无匹配则 no-op。
void scrollToFirstError(
  Map<String, String> errors,
  Map<String, GlobalKey> fieldKeys,
) {
  if (errors.isEmpty) return;
  final firstField = errors.keys.first;
  final ctx = fieldKeys[firstField]?.currentContext;
  if (ctx != null) {
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      alignment: 0.1,
    );
  }
}
