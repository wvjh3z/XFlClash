/// 领域错误 sealed（D26）— 与 SDK `SdkError` 子类型一一对应（D67）。
///
/// **零 SDK 类型穿透**（conventions §2.1 / Property 2）：UI / Provider 只依赖本类型，
/// 不直接 import SDK 的 `SdkError`。反腐层 `_mapError(SdkError) → XbDomainError` 是唯一翻译入口。
///
/// **🔴 实施期 spec 订正（W2.3）**：tasks W2.3.1 写「freezed sealed class」，但 design Data Models
/// 的真实代码是**手写 sealed class**（带共享 `message` 基类字段 + 位置构造 + `super.message`）。
/// freezed v3 sealed 不便表达共享基类字段，且这些类型简单（无 copyWith/json 需求），手写更准确。
/// 已按 design 实际代码实现，design 修订记录登记此订正。
///
/// **kind 复用 SDK enum**（typedef，第 12 轮）：`XbBusinessKind`/`XbNetworkKind` 是 SDK
/// `BusinessErrorKind`/`NetworkErrorKind` 的 typedef，避免 `_mapError` 同名不同类型转换编译失败。
/// `XbBusiness` 故意**不持** SDK `BusinessError.httpStatusCode`（业务层不暴露 HTTP 细节，C37）。
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show BusinessErrorKind, NetworkErrorKind, RateLimitKind;

/// 业务错误子类别名 — 直接复用 SDK `BusinessErrorKind`（barrel 已导出，枚举数见 conventions §2.6.A）。
typedef XbBusinessKind = BusinessErrorKind;

/// 网络错误子类别名 — 直接复用 SDK `NetworkErrorKind`（timeout/connectionFailed/cancelled/unknownHost/unknown）。
typedef XbNetworkKind = NetworkErrorKind;

/// 客户端领域错误 sealed 基类。所有 `XboardService` 方法失败时返回其子类型。
sealed class XbDomainError {
  /// 用户可读 message（后端透传 / 客户端翻译）。
  final String message;

  const XbDomainError(this.message);

  factory XbDomainError.unauthorized(String m) = XbUnauthorized;
  factory XbDomainError.rateLimit(RateLimitKind k, int? minutes, String m) =
      XbRateLimit;
  factory XbDomainError.business(
    BusinessErrorKind k,
    String m,
    Map<String, List<String>>? errors,
  ) = XbBusiness;
  factory XbDomainError.network(XbNetworkKind k, String m) = XbNetwork;
  factory XbDomainError.server(int status, String m) = XbServer;
  factory XbDomainError.security(String m) = XbSecurity;
  factory XbDomainError.unexpected(String op, String m) = XbUnexpected;
}

/// 401 / 403 — 未认证（token 失效 / 已登出 / 封禁）。映射 SDK `UnauthorizedError`。
final class XbUnauthorized extends XbDomainError {
  const XbUnauthorized(super.message);
}

/// 429 — 限流（R1/R2/R3 倒计时 UI）。映射 SDK `RateLimitError`。
final class XbRateLimit extends XbDomainError {
  /// 限流类型（login / register / forgotPassword / generic）。
  final RateLimitKind kind;

  /// 多少分钟后可重试（null = 后端未提供）。
  final int? retryAfterMinutes;

  const XbRateLimit(this.kind, this.retryAfterMinutes, String m) : super(m);
}

/// 4xx 业务错误。映射 SDK `BusinessError`（**不持 httpStatusCode**，C37）。
final class XbBusiness extends XbDomainError {
  /// 业务错误子类型（22 子类，UI 据此显示精准文案）。
  final BusinessErrorKind kind;

  /// Laravel 422 字段级错误（`{field: [msgs]}`）。
  final Map<String, List<String>>? validationErrors;

  const XbBusiness(this.kind, String m, this.validationErrors) : super(m);
}

/// 网络层错误（无 HTTP 响应）。映射 SDK `NetworkError`。
final class XbNetwork extends XbDomainError {
  /// 网络失败具体类型。
  final XbNetworkKind kind;

  const XbNetwork(this.kind, String m) : super(m);
}

/// 5xx 服务端错误（有响应但服务端故障）。映射 SDK `ServerError`。
final class XbServer extends XbDomainError {
  /// HTTP 状态码（500-599）。
  final int httpStatusCode;

  const XbServer(this.httpStatusCode, String m) : super(m);
}

/// 安全层错误（证书 pinning / TLS / Bootstrap 解密失败）。映射 SDK `SecurityError`。
final class XbSecurity extends XbDomainError {
  const XbSecurity(super.message);
}

/// 未预期错误（parse 失败 / NPE / 未知异常）。映射 SDK `UnexpectedError`。
final class XbUnexpected extends XbDomainError {
  /// 触发异常的操作名（便于日志定位）。
  final String operation;

  const XbUnexpected(this.operation, String m) : super(m);
}
