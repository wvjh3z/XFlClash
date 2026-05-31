/// UI 侧 checkout 结果 sealed 5 分支（映射 SDK CheckoutOutcome；F346/F350）。
///
/// 类名 `CheckoutOutcomeUi`（与 SDK `CheckoutOutcome` 区分语义在外层 `*Outcome` vs `*OutcomeUi`）；
/// 分支类名与 SDK 同名。手写 sealed（无 json/copyWith 需求）。
library;

/// checkout 5 分支结果。
sealed class CheckoutOutcomeUi {
  const CheckoutOutcomeUi();
}

/// 跳系统浏览器（R8.6 / 7 个跳转支付插件）。
final class CheckoutRedirect extends CheckoutOutcomeUi {
  final String url;
  const CheckoutRedirect(this.url);
}

/// qr_flutter 渲染 + 轮询订单（AlipayF2f 等）。
final class CheckoutQrCode extends CheckoutOutcomeUi {
  final String qrCodeUrl;
  const CheckoutQrCode(this.qrCodeUrl);
}

/// 余额抵扣全额，等价 R8.10 完成。
final class CheckoutPaid extends CheckoutOutcomeUi {
  const CheckoutPaid();
}

/// 用户取消 / 静默回退。
final class CheckoutCanceled extends CheckoutOutcomeUi {
  final String? message;
  const CheckoutCanceled([this.message]);
}

/// checkout 失败。
final class CheckoutFailed extends CheckoutOutcomeUi {
  final String message;
  const CheckoutFailed(this.message);
}
