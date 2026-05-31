/// 客户端统一结果 sealed（反腐层归一 DD-3 / Property 4）。
///
/// 所有 `XboardService` 方法返回 `XbResult<T>`，吸收 SDK「有的返 SdkResult / 有的 throw」的
/// 双形态差异（DD-3）。UI / Provider 用 `switch` 编译期穷举 success / failure。
///
/// **命名（第 22 轮纠正）**：分支名 `XbSuccess` / `XbFailure`，**不叫 `Ok` / `Err`** —— 与 SDK
/// `Success` / `Failure` 命名平齐但加 `Xb` 前缀，避免类型穿透（Property 2/4）。
///
/// **🔴 实施期 spec 订正（W2.7）**：tasks W2.7.1 写「freezed sealed」，但 design Data Models
/// 真实代码是**手写 sealed**（泛型 `<T>` + 位置构造）。手写更准确（freezed 泛型 sealed 冗余），
/// 已按 design 实际代码实现。
library;

import 'xb_domain_error.dart';

/// 反腐层统一结果。
sealed class XbResult<T> {
  const XbResult();

  factory XbResult.success(T data) = XbSuccess<T>;
  factory XbResult.failure(XbDomainError error) = XbFailure<T>;

  /// sealed switch 帮助方法 —— 强制处理 success / failure 两分支。
  R when<R>({
    required R Function(T data) success,
    required R Function(XbDomainError error) failure,
  }) {
    final self = this;
    return switch (self) {
      XbSuccess<T>(:final data) => success(data),
      XbFailure<T>(:final error) => failure(error),
    };
  }

  /// 是否成功。
  bool get isSuccess => this is XbSuccess<T>;

  /// 成功数据（失败时 null）。
  T? get dataOrNull => switch (this) {
        XbSuccess<T>(:final data) => data,
        XbFailure<T>() => null,
      };

  /// 失败错误（成功时 null）。
  XbDomainError? get errorOrNull => switch (this) {
        XbSuccess<T>() => null,
        XbFailure<T>(:final error) => error,
      };
}

/// 成功分支 — 持有返回数据。
final class XbSuccess<T> extends XbResult<T> {
  /// 操作成功的返回数据。
  final T data;

  const XbSuccess(this.data);
}

/// 失败分支 — 持有领域错误。
final class XbFailure<T> extends XbResult<T> {
  /// 归一后的领域错误。
  final XbDomainError error;

  const XbFailure(this.error);
}
