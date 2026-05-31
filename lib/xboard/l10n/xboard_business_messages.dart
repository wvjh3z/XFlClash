/// BusinessErrorKind → 本地化 UI 文案查找（β-8 / DD-16）。
///
/// **i18n 分层（DD-16 / F398）**：客户端新增 UI 走 `lib/xboard/l10n/` 自维护 arb（en/ru/zh_CN
/// 三语，v0.1 实际只用 zh_CN，D15）。本文件提供运行期 kind → key → 文案查找；arb 文件
/// （`xboard_zh_CN.arb` / `xboard_en.arb` / `xboard_ru.arb`）是 22 子类文案 SSoT。
///
/// **为何不走 flutter_intl codegen**（实施期取舍）：FlClash 主仓 intl_utils 只扫 `arb/` 顶层目录
/// 生成 `AppLocalizations`；把 Xboard arb 塞进去会污染底座 478 keys + 每次 upstream sync 冲突。
/// 客户端 22 条业务文案用轻量运行期 map（locale → {key: text}）更稳，零 codegen 耦合，
/// 与 conventions「客户端 UI 文案走客户端 arb」一致。tasks W2.5.4 的「flutter_intl 配置」据此简化。
///
/// **i18n key 规约**：每个 `BusinessErrorKind.<name>` 对应 key `xb_business_<name>`，与 arb 严格对齐。
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show BusinessErrorKind;

/// 支持的客户端 locale（DD-16：en/ru/zh_CN 三语；其他 → en 兜底）。
enum XbLocale { zhCN, en, ru }

/// 把 Flutter locale code 映射到 Xboard 支持的 3 语（ja / 其他 → en，DD-16 / §E i18n fallback）。
XbLocale resolveXbLocale(String languageCode) => switch (languageCode) {
      'zh' => XbLocale.zhCN,
      'ru' => XbLocale.ru,
      _ => XbLocale.en,
    };

/// BusinessErrorKind → i18n key（`xb_business_<enumName>`）。
String businessErrorKey(BusinessErrorKind kind) => 'xb_business_${kind.name}';

/// BusinessErrorKind 本地化文案查找（22 子类全覆盖，β-8）。
///
/// 与 `xboard_zh_CN.arb` / `xboard_en.arb` / `xboard_ru.arb` 严格对齐（同 SSoT）；
/// 运行期 map 内嵌一份以避免 asset 加载（22 条文案体积极小）。
String localizedBusinessMessage(BusinessErrorKind kind, XbLocale locale) {
  final table = _messages[locale]!;
  // generic 作为兜底；理论上 22 子类全覆盖，缺失时回退 generic。
  return table[kind] ?? table[BusinessErrorKind.generic]!;
}

const Map<XbLocale, Map<BusinessErrorKind, String>> _messages = {
  XbLocale.zhCN: {
    BusinessErrorKind.banned: '账号已被封禁，请联系客服',
    BusinessErrorKind.emailVerifyCodeRateLimit: '请稍后再试',
    BusinessErrorKind.wrongPlanPeriod: '套餐周期不可用，请重新选择',
    BusinessErrorKind.invalidEmailCode: '验证码错误或已过期',
    BusinessErrorKind.invalidInviteCode: '邀请码无效',
    BusinessErrorKind.inviteCodeRequired: '请填写邀请码',
    BusinessErrorKind.emailAlreadyExists: '邮箱已被使用，请直接登录',
    BusinessErrorKind.emailVerifyCodeEmpty: '请输入验证码',
    BusinessErrorKind.insufficientBalance: '余额不足',
    BusinessErrorKind.pendingOrderConflict: '您有未支付订单，是否查看？',
    BusinessErrorKind.couponFailed: '优惠券应用失败',
    BusinessErrorKind.paymentMethodUnavailable: '支付方式暂不可用',
    BusinessErrorKind.orderNotFoundOrPaid: '订单状态已变更',
    BusinessErrorKind.cancelOnlyPendingOrders: '该订单不可取消',
    BusinessErrorKind.planNotFound: '套餐不存在',
    BusinessErrorKind.inviteCodeGenLimitReached: '邀请码已达上限',
    BusinessErrorKind.withdrawAmountBelowMinimum: '提现金额低于最低门槛',
    BusinessErrorKind.withdrawMethodNotSupported: '提现方式不支持',
    BusinessErrorKind.withdrawClosed: '提现功能已关闭',
    BusinessErrorKind.freeOrderPaidFailed: '支付失败，请重试',
    BusinessErrorKind.validationFailed: '请检查输入项',
    BusinessErrorKind.generic: '操作失败，请稍后重试',
  },
  XbLocale.en: {
    BusinessErrorKind.banned: 'Your account has been suspended. Please contact support.',
    BusinessErrorKind.emailVerifyCodeRateLimit: 'Please try again later',
    BusinessErrorKind.wrongPlanPeriod: 'This plan period is unavailable, please re-select',
    BusinessErrorKind.invalidEmailCode: 'Verification code is incorrect or expired',
    BusinessErrorKind.invalidInviteCode: 'Invalid invite code',
    BusinessErrorKind.inviteCodeRequired: 'An invite code is required',
    BusinessErrorKind.emailAlreadyExists: 'Email already in use, please sign in',
    BusinessErrorKind.emailVerifyCodeEmpty: 'Please enter the verification code',
    BusinessErrorKind.insufficientBalance: 'Insufficient balance',
    BusinessErrorKind.pendingOrderConflict: 'You have an unpaid order. View it?',
    BusinessErrorKind.couponFailed: 'Failed to apply coupon',
    BusinessErrorKind.paymentMethodUnavailable: 'Payment method temporarily unavailable',
    BusinessErrorKind.orderNotFoundOrPaid: 'Order status has changed',
    BusinessErrorKind.cancelOnlyPendingOrders: 'This order cannot be cancelled',
    BusinessErrorKind.planNotFound: 'Plan not found',
    BusinessErrorKind.inviteCodeGenLimitReached: 'Invite code generation limit reached',
    BusinessErrorKind.withdrawAmountBelowMinimum: 'Withdrawal amount below minimum',
    BusinessErrorKind.withdrawMethodNotSupported: 'Withdrawal method not supported',
    BusinessErrorKind.withdrawClosed: 'Withdrawals are closed',
    BusinessErrorKind.freeOrderPaidFailed: 'Payment failed, please retry',
    BusinessErrorKind.validationFailed: 'Please check your input',
    BusinessErrorKind.generic: 'Operation failed, please try again later',
  },
  XbLocale.ru: {
    BusinessErrorKind.banned: 'Ваш аккаунт заблокирован. Обратитесь в поддержку.',
    BusinessErrorKind.emailVerifyCodeRateLimit: 'Повторите попытку позже',
    BusinessErrorKind.wrongPlanPeriod: 'Этот период тарифа недоступен, выберите другой',
    BusinessErrorKind.invalidEmailCode: 'Код подтверждения неверен или истёк',
    BusinessErrorKind.invalidInviteCode: 'Недействительный код приглашения',
    BusinessErrorKind.inviteCodeRequired: 'Требуется код приглашения',
    BusinessErrorKind.emailAlreadyExists: 'Email уже используется, выполните вход',
    BusinessErrorKind.emailVerifyCodeEmpty: 'Введите код подтверждения',
    BusinessErrorKind.insufficientBalance: 'Недостаточно средств',
    BusinessErrorKind.pendingOrderConflict: 'У вас есть неоплаченный заказ. Открыть?',
    BusinessErrorKind.couponFailed: 'Не удалось применить купон',
    BusinessErrorKind.paymentMethodUnavailable: 'Способ оплаты временно недоступен',
    BusinessErrorKind.orderNotFoundOrPaid: 'Статус заказа изменился',
    BusinessErrorKind.cancelOnlyPendingOrders: 'Этот заказ нельзя отменить',
    BusinessErrorKind.planNotFound: 'Тариф не найден',
    BusinessErrorKind.inviteCodeGenLimitReached: 'Достигнут лимит создания кодов приглашения',
    BusinessErrorKind.withdrawAmountBelowMinimum: 'Сумма вывода ниже минимальной',
    BusinessErrorKind.withdrawMethodNotSupported: 'Способ вывода не поддерживается',
    BusinessErrorKind.withdrawClosed: 'Вывод средств закрыт',
    BusinessErrorKind.freeOrderPaidFailed: 'Ошибка оплаты, повторите',
    BusinessErrorKind.validationFailed: 'Проверьте введённые данные',
    BusinessErrorKind.generic: 'Операция не удалась, повторите позже',
  },
};
