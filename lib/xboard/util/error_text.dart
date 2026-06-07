/// 领域错误 → 用户可读文案的**统一解析入口**（触类旁通：根治"后端 message 被吞成兜底文案"）。
///
/// **背景**：登录失败时后端返「邮箱或密码错误」(HTTP 400 → BusinessError.generic)，
/// 早期 UI 一律显示本地化兜底「操作失败，请稍后重试」，丢了后端真实原因。其余页面
/// （订单/套餐加载、XboardStateView）也有同样问题。本函数把规则收口一处，各页复用。
///
/// **核心规则**：
/// - 有精准客户端文案的子类型（限流倒计时 / 已知业务 kind / 网络 / 未认证 / 安全）→ 用客户端文案；
/// - **语义模糊、后端 message 才是最精准信息**的情况（business.generic / business.validationFailed /
///   server 5xx / unexpected）→ **优先透传后端 message**，仅当后端 message 为空才回退兜底。
///
/// 这样既保留客户端对已知错误的本地化与交互（如 banned 强制登出、限流倒计时），又不再
/// 吞掉后端对未建模错误给出的精准中文提示。
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show BusinessErrorKind;

import '../l10n/xboard_business_messages.dart';
import '../models/xb_domain_error.dart';

/// 解析领域错误为用户可读文案。
///
/// [fallback] 是兜底文案（后端 message 也为空、且无更精准客户端文案时用），各页可传场景化默认
/// （如「登录失败，请稍后重试」/「加载订单失败」）。[locale] 决定已知业务 kind 的本地化语言。
String resolveErrorText(
  XbDomainError error, {
  String fallback = '操作失败，请稍后重试',
  XbLocale locale = XbLocale.zhCN,
}) {
  final backendMsg = error.message.trim();
  switch (error) {
    case XbUnauthorized():
      return '登录已过期，请重新登录';
    case XbRateLimit(:final retryAfterMinutes):
      return retryAfterMinutes != null
          ? '请求过于频繁，请 $retryAfterMinutes 分钟后重试'
          : '请求过于频繁，请稍后重试';
    case XbBusiness(:final kind):
      // generic / validationFailed：后端 message 最精准（含未建模的业务限制原文）→ 优先透传，
      // 但中文环境下把常见后端英文校验提示翻成中文（密码长度/邮箱格式等），避免中文 app 漏英文。
      if (kind == BusinessErrorKind.generic ||
          kind == BusinessErrorKind.validationFailed) {
        return backendMsg.isNotEmpty
            ? _zhFromBackend(backendMsg, locale)
            : localizedBusinessMessage(kind, locale);
      }
      // 已知子类型：用客户端本地化文案（统一口径，不受后端文案波动影响）。
      return localizedBusinessMessage(kind, locale);
    case XbNetwork():
      return '网络异常，请检查网络后重试';
    case XbServer():
      // 5xx 后端常返有意义的故障说明 → 优先透传，否则兜底。
      return backendMsg.isNotEmpty
          ? _zhFromBackend(backendMsg, locale)
          : '服务异常，请稍后重试';
    case XbSecurity():
      return '安全连接失败';
    case XbUnexpected():
      return backendMsg.isNotEmpty ? _zhFromBackend(backendMsg, locale) : fallback;
  }
}

/// 把常见后端英文校验/业务提示翻成中文（仅 zh 环境）。无匹配 → 原样返回后端 message。
///
/// 后端（Laravel）validation 文案多为英文（如 "The password must be at least 8 characters."）。
/// 中文 app 直接透传会漏英文，这里做关键短语映射（不穷举，覆盖高频项；未命中保留原文不丢信息）。
String _zhFromBackend(String msg, XbLocale locale) {
  if (locale != XbLocale.zhCN) return msg;
  final m = msg.toLowerCase();
  // —— 密码 ——
  if (m.contains('password') && (m.contains('at least') || m.contains('minimum') || m.contains('8'))) {
    return '密码至少需要 8 位';
  }
  if (m.contains('password') && m.contains('confirm')) return '两次输入的密码不一致';
  if (m.contains('password') && (m.contains('incorrect') || m.contains('wrong') || m.contains('not match'))) {
    return '邮箱或密码错误';
  }
  // —— 邮箱 ——
  if (m.contains('email') && (m.contains('valid') || m.contains('format') || m.contains('invalid'))) {
    return '邮箱格式不正确';
  }
  if (m.contains('email') && (m.contains('already') || m.contains('taken') || m.contains('exists'))) {
    return '邮箱已被使用，请直接登录';
  }
  if (m.contains('email') && m.contains('required')) return '请填写邮箱';
  // —— 验证码 ——
  if ((m.contains('code') || m.contains('verification')) &&
      (m.contains('invalid') || m.contains('incorrect') || m.contains('expired'))) {
    return '验证码错误或已过期';
  }
  if (m.contains('code') && m.contains('required')) return '请输入验证码';
  // —— 通用 required / invalid 兜底（仍是英文时给个中文）——
  if (m == 'the given data was invalid.' || m.contains('validation')) {
    return '请检查输入项';
  }
  return msg; // 未命中 → 保留后端原文（不丢信息）
}

/// 是否应展示「重试」按钮（网络 / 服务端 / 未预期 → 可重试；业务 / 限流 / 未认证 / 安全 → 不可）。
bool errorAllowsRetry(XbDomainError error) => switch (error) {
      XbNetwork() || XbServer() || XbUnexpected() => true,
      _ => false,
    };
