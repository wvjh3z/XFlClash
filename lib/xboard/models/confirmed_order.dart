import 'xb_domain_types.dart';

/// Renewal identity depends on the purchased plan and its expiry. Quota is
/// checked separately (e.g. for reset eligibility and quote changes).
int? activePurchasePlanId(int? planId, DateTime? expiry) =>
    planId != null && planId > 0 && (expiry?.isAfter(DateTime.now()) ?? true)
    ? planId
    : null;

/// A pre-payment estimate, before balance credits or payment-channel fees.
class ConfirmedOrderQuote {
  const ConfirmedOrderQuote({
    required this.planId,
    required this.planName,
    required this.period,
    required this.estimatedCents,
    required this.catalogCents,
    this.couponCode,
    this.couponEndsAt,
    this.expectedSubscription,
  });

  final int planId;
  final String planName;
  final XbPlanPeriod period;
  final int estimatedCents;
  /// Price of the selected period before applying any coupon or credit.
  final int catalogCents;
  final String? couponCode;
  final DateTime? couponEndsAt;
  final ConfirmedOrderSubscription? expectedSubscription;
}

/// Inputs that determined the subscription impact explained before checkout.
class ConfirmedOrderSubscription {
  ConfirmedOrderSubscription({
    required this.planId,
    required this.totalBytes,
    required this.expiredAt,
  }) : wasActive = activePurchasePlanId(planId, expiredAt) != null;

  final int? planId;
  final int totalBytes;
  final DateTime? expiredAt;
  final bool wasActive;

  int? get activePlanId => wasActive ? planId : null;

  bool matches(int? id, int bytes, DateTime? expiration) =>
      planId == id &&
      totalBytes == bytes &&
      (expiredAt == null
          ? expiration == null
          : expiration != null && expiredAt!.isAtSameMomentAs(expiration)) &&
      wasActive == (activePurchasePlanId(id, expiration) != null);
}

enum ConfirmedOrderStage { checking, awaitingConfirmation, cancelling, checkingCancellation, creating, verifying }

class ConfirmedOrderConflict {
  const ConfirmedOrderConflict({
    required this.sameSelection,
    required this.quote,
    required this.existingTradeNo,
    required this.existingPlanName,
    required this.existingPeriod,
    required this.existingPayableCents,
    this.existingBalanceCents = 0,
    this.existingAppliedSurplusCents = 0,
  });

  final bool sameSelection;
  final ConfirmedOrderQuote quote;
  final String existingTradeNo;
  final String existingPlanName;
  final XbPlanPeriod existingPeriod;
  final int existingPayableCents;
  /// Account balance already deducted on the verified pending order.
  final int existingBalanceCents;
  /// Old-plan surplus actually applied, excluding excess returned on opening.
  /// Zero means no deduction; null means the wire evidence is insufficient.
  final int? existingAppliedSurplusCents;

  /// Compatibility for consumers of the old aggregate. New UI labels the
  /// two sources separately; neither is derived from the new catalog price.
  int? get existingCreditCents => existingAppliedSurplusCents == null
      ? null : existingBalanceCents + existingAppliedSurplusCents!;
}

/// Convert catalog yuan back to integer cents; do not round away sub-cent
/// prices. The round trip allows only the error from double representation.
int? orderQuoteCents(double amountYuan) {
  if (!amountYuan.isFinite || amountYuan < 0 || amountYuan >= 1e12) return null;
  final cents = (amountYuan * 100).round();
  return cents / 100 == amountYuan ? cents : null;
}
