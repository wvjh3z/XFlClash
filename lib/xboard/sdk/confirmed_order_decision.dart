part of 'xboard_service_impl.dart';

class _OrderDecisionSession {
  _OrderDecisionSession(this.revision);

  final int? revision;
  final Set<String> writes = {};
  bool createUnconfirmed = false;
  ({String tradeNo, int planId, PlanPeriod period})? knownCreation;
  _DecisionOrder? cancellationToVerify;
}

class _DecisionOrder {
  const _DecisionOrder({
    required this.tradeNo,
    this.status,
    this.planId,
    this.period,
    this.payableCents,
    this.balanceCents,
    this.surplusCents,
    this.creditCents,
    this.planName,
  });

  final String tradeNo;
  final OrderStatus? status;
  final int? planId;
  final PlanPeriod? period;
  final int? payableCents;
  final int? balanceCents;
  final int? surplusCents;
  final int? creditCents;
  final String? planName;
  int? get appliedSurplusCents => appliedOrderSurplusCents(
    net: payableCents!, balance: balanceCents ?? 0,
    surplus: surplusCents ?? 0, credit: creditCents,
  );

  bool get complete =>
      status != null &&
      planId != null &&
      period != null &&
      payableCents != null;

  bool matchesKnownFields(_DecisionOrder fresh) =>
      tradeNo == fresh.tradeNo &&
      (status == null || status == fresh.status) &&
      (planId == null || planId == fresh.planId) &&
      (period == null || period == fresh.period) &&
      (payableCents == null || payableCents == fresh.payableCents) &&
      (balanceCents == null || balanceCents == fresh.balanceCents) &&
      (surplusCents == null || surplusCents == fresh.surplusCents) &&
      (creditCents == null || creditCents == fresh.creditCents);

  bool samePendingQuote(_DecisionOrder other) =>
      status == OrderStatus.pending &&
      other.status == OrderStatus.pending &&
      tradeNo == other.tradeNo &&
      planId == other.planId &&
      period == other.period &&
      payableCents == other.payableCents &&
      (balanceCents ?? 0) == (other.balanceCents ?? 0) &&
      (surplusCents ?? 0) == (other.surplusCents ?? 0) &&
      creditCents == other.creditCents;

  bool confirmsCancellationOf(_DecisionOrder old) =>
      tradeNo == old.tradeNo &&
      status == OrderStatus.cancelled &&
      (planId == null || planId == old.planId) &&
      (period == null || period == old.period);
}

class _DecisionOrderSnapshot {
  const _DecisionOrderSnapshot(this.tradeNos, this.pending);

  final Set<String> tradeNos;
  final _DecisionOrder? pending;
}

final _orderIdentifier = RegExp(r'^[a-zA-Z0-9_-]+$');
const _paginationMarkers = {
  'current_page',
  'last_page',
  'per_page',
  'next_page_url',
  'page',
  'page_size',
  'has_more',
  'cursor',
  'links',
  'meta',
};

String? _decisionTradeNo(Object? value) =>
    value is String && _orderIdentifier.hasMatch(value)
    ? value
    : null;

int? _decisionAmount(Object? value) =>
    value is int && value >= 0 && value < 100000000000000 ? value : null;

Never _unknownOrderResponse() =>
    throw EndpointException('订单字段或状态无法确认', 200);

_DecisionOrder _parseDecisionOrder(Object? raw, {bool detail = false}) {
  if (raw is! Map<String, dynamic>) _unknownOrderResponse();
  final tradeNo = _decisionTradeNo(raw['trade_no']);
  final rawStatus = raw['status'];
  final status = rawStatus is int ? OrderStatus.fromRaw(rawStatus) : null;
  // Past terminal orders don't need price/plan data. But the identifier and
  // state are always required to establish completeness and uniqueness.
  if (tradeNo == null || (rawStatus != null && status == null)) {
    _unknownOrderResponse();
  }
  final rawPlanId = raw['plan_id'];
  final planId = rawPlanId is int && rawPlanId > 0 ? rawPlanId : null;
  final rawPeriod = raw['period'];
  final period = rawPeriod is String ? PlanPeriod.fromValue(rawPeriod) : null;
  final rawPayable = raw['total_amount'];
  final payableCents = _decisionAmount(rawPayable);
  final rawBalance = raw['balance_amount'];
  final balanceCents = _decisionAmount(rawBalance);
  final rawSurplus = raw['surplus_amount'];
  final surplusCents = _decisionAmount(rawSurplus);
  final rawCredit = raw['surplus_credit'];
  final creditCents = _decisionAmount(rawCredit);
  if ((detail || !(status?.isFinal ?? false)) &&
      ((rawPlanId != null && planId == null) ||
          (rawPeriod != null && period == null) ||
          (rawPayable != null && payableCents == null) ||
          (rawBalance != null && balanceCents == null) ||
          (rawSurplus != null && surplusCents == null) ||
          (rawCredit != null && creditCents == null))) {
    _unknownOrderResponse();
  }
  final rawPlan = raw['plan'];
  final name = rawPlan is Map<String, dynamic> ? rawPlan['name'] : null;
  return _DecisionOrder(
    tradeNo: tradeNo,
    status: status,
    planId: planId,
    period: period,
    payableCents: payableCents,
    balanceCents: balanceCents,
    surplusCents: surplusCents,
    creditCents: creditCents,
    planName: name is String && name.trim().isNotEmpty ? name : null,
  );
}

extension _ConfirmedOrderDecision on XboardServiceImpl {
  Future<T> _withKnownWriteRejection<T>(Future<T> Function() write) async {
    try {
      return await write();
    } on ApiException catch (error) {
      // Unclassified SDK panel parsing failures don't prove a write rejected.
      final code = error.code;
      if (code == null || code < 400 || code >= 500) _unknownOrderResponse();
      rethrow;
    }
  }

  Future<bool> _matchesExpectedSubscription(
    ConfirmedOrderSubscription? expected,
  ) async {
    if (expected == null) return true;
    final read = await _runGuarded(
      'getSubscription',
      () => _sdk.subscription.getSubscription(),
    );
    final latest = read.dataOrNull;
    return latest != null &&
        expected.matches(
          latest.planId,
          latest.transferEnable ?? 0,
          latest.expiredAt,
        );
  }

  Future<({Map<String, dynamic> raw, _DecisionOrder order})>
  _readOrderDetail(String tradeNo) async {
    if (_decisionTradeNo(tradeNo) == null) {
      throw ParameterException('订单号无效');
    }
    final response = await _sdk.httpService.getRequest(
      '/api/v1/user/order/detail?trade_no=${Uri.encodeQueryComponent(tradeNo)}',
    );
    final raw = response['data'];
    if (response['success'] != true || raw is! Map<String, dynamic>) {
      _unknownOrderResponse();
    }
    final order = _parseDecisionOrder(raw, detail: true);
    if (order.tradeNo != tradeNo || order.status == null) {
      _unknownOrderResponse();
    }
    return (raw: raw, order: order);
  }

  Future<_DecisionOrder> _decisionOrderDetail(String tradeNo) async =>
      (await _readOrderDetail(tradeNo)).order;

  Future<OrderDetail> _verifiedOrderDetail(String tradeNo) async {
    final result = await _readOrderDetail(tradeNo);
    final order = result.order;
    final raw = result.raw;
    if (!order.complete) _unknownOrderResponse();
    final discount = raw['discount_amount'];
    final fee = raw['handling_amount'];
    if ((discount != null && _decisionAmount(discount) == null) ||
        (fee != null && (fee is! int || _decisionAmount(fee.abs()) == null))) {
      _unknownOrderResponse();
    }
    // Critical fields were validated before the SDK DTO's numeric coercion
    // and the presentation mapping. No additional endpoint per poll.
    final m = OrderModel.fromJson(raw);
    return OrderDetail(
      summary: _mapOrderSummary(m),
      balanceAmountYuan: _centsToYuan(m.balanceAmount),
      surplusAmountYuan: _centsToYuan(m.surplusAmount),
      surplusCreditYuan: _centsToYuan(m.refundAmount),
      discountAmountYuan: _centsToYuan(m.discountAmount),
      handlingAmountYuan: _centsToYuan(m.handlingAmount),
    );
  }

  Future<XbResult<void>> _preflightOrderWrite(
    String tradeNo,
    String operation,
  ) async {
    final detail = await getOrder(tradeNo);
    if (detail.dataOrNull?.summary.status != XbOrderStatus.pending) {
      // No write was sent. Still request a status refresh in existing
      // consumers, rather than letting their last known display authorize it.
      return XbFailure(
        XbUnconfirmed(operation, '无法确认订单仍待支付，本次未发送请求，请核对订单状态。'),
      );
    }
    return const XbSuccess(null);
  }

  Future<_DecisionOrderSnapshot> _decisionOrderSnapshot() async {
    // This Xboard endpoint returns the whole history. The SDK pages only its
    // local cache of that response, and its DTO truncates numeric plan/status
    // fields. Read the same endpoint via the existing authenticated SDK HTTP
    // service to keep the wire fields and the single complete snapshot.
    final response = await _sdk.httpService.getRequest(
      '/api/v1/user/order/fetch',
    );
    final rows = response['data'];
    final total = response['total'];
    if (response['success'] != true ||
        rows is! List ||
        (total != null && (total is! int || total != rows.length)) ||
        _paginationMarkers.any(response.containsKey)) {
      _unknownOrderResponse();
    }
    final seen = <String>{};
    _DecisionOrder? pending;
    for (final raw in rows) {
      final row = _parseDecisionOrder(raw);
      if (!seen.add(row.tradeNo)) _unknownOrderResponse();
      if (row.status == OrderStatus.processing) _unknownOrderResponse();
      if (row.status?.isFinal ?? false) continue;

      // A candidate is always checked by its own order number. Missing list
      // fields may be filled in, but changed known fields require a new intent.
      final detail = await _decisionOrderDetail(row.tradeNo);
      if (!row.matchesKnownFields(detail)) _unknownOrderResponse();
      if (detail.status?.isFinal ?? false) continue;
      if (detail.status != OrderStatus.pending ||
          !detail.complete ||
          pending != null) {
        _unknownOrderResponse();
      }
      pending = detail;
    }
    return _DecisionOrderSnapshot(seen, pending);
  }

  Future<XbResult<String?>> _decideConfirmedOrder(
    _OrderDecisionSession session,
    ConfirmedOrderQuote quote,
    bool Function() current,
    Future<bool> Function(ConfirmedOrderConflict) confirm,
    void Function(ConfirmedOrderStage stage)? onStage,
  ) async {
    const stopped = XbSuccess<String?>(null);
    const review = XbFailure<String?>(
      XbUnconfirmed('confirmOrder', '订单状态发生变化或无法确认，请先前往“我的订单”核对。'),
    );
    const createUnknown = XbFailure<String?>(
      XbUnconfirmed('createOrder', '下单结果尚未确认，请核对“我的订单”，不要重复下单。'),
    );
    const cancelUnknown = XbFailure<String?>(
      XbUnconfirmed('cancelOrder', '未能确认旧单已取消，本次没有创建新订单，请核对“我的订单”。'),
    );
    const cancelledWithoutReplacement = XbFailure<String?>(
      XbUnconfirmed('cancelOrder', '旧单已取消，本次没有创建新订单，请核对“我的订单”。'),
    );
    const expiredCoupon = XbFailure<String?>(
      XbBusiness(BusinessErrorKind.generic, '优惠码已过期，请重新验证。', null),
    );
    const changedSubscription = XbFailure<String?>(
      XbBusiness(BusinessErrorKind.generic, '当前套餐状态已变化或无法核对，请返回重试。', null),
    );
    if (quote.planId <= 0 || _decisionAmount(quote.estimatedCents) == null) {
      return const XbFailure(
        XbBusiness(BusinessErrorKind.generic, '无法确认套餐价格，请返回重选。', null),
      );
    }
    bool couponCurrent() =>
        quote.couponEndsAt?.isAfter(DateTime.now()) ?? true;
    if (!couponCurrent()) return expiredCoupon;
    onStage?.call(ConfirmedOrderStage.checking);

    // A coupon changes the estimate, not the catalog price the user selected.
    // Reset eligibility is independent of renewal permission: re-read the same
    // catalog the reset dialog used rather than the renewal-only ID lookup.
    Future<bool> quoteStillAvailable() async {
      final reset = quote.period == XbPlanPeriod.resetTraffic;
      final lookup = await _runGuarded('getPlan', () => _sdk.httpService.getRequest(
        reset ? '/api/v1/user/plan/fetch' : '/api/v1/user/plan/fetch?id=${quote.planId}',
      ));
      final body = lookup.dataOrNull;
      if (body == null || body['success'] != true) return false;
      Object? plan = body['data'];
      if (reset) {
        if (plan is! List || quote.expectedSubscription?.planId != quote.planId) return false;
        final matches = plan.whereType<Map>().where((p) => p['id'] == quote.planId);
        if (matches.length != 1) return false;
        plan = matches.single;
      }
      if (plan is! Map || plan['id'] != quote.planId) return false;
      if (!reset && quote.expectedSubscription?.planId == quote.planId &&
          plan['renew'] != true && plan['renew'] != 1) {
        return false;
      }
      final raw = plan[_toSdkPeriod(quote.period).value];
      final cents = raw is num ? raw : raw is String ? num.tryParse(raw) : null;
      return cents != null && cents.isFinite && cents >= 0 && cents < 1e14 &&
          (reset || quote.catalogCents > 0) && (cents - quote.catalogCents).abs() <= 0.000001;
    }
    const changedQuote = XbFailure<String?>(XbBusiness(BusinessErrorKind.generic,
        '套餐、所选周期或价格已变化，或暂时无法核实，请返回重新选择。', null));

    // If the old response was lost, only read. A cancelled detail is not
    // permission to continue a previous replacement on a later tap.
    if (session.createUnconfirmed) {
      if (session.knownCreation case final prior?) {
        final checked = await _runGuarded(
          'getOrder',
          () => _decisionOrderDetail(prior.tradeNo),
        );
        if (!current()) return stopped;
        final order = checked.dataOrNull;
        if (order != null &&
            order.complete &&
            order.planId == prior.planId &&
            order.period == prior.period) {
          session.createUnconfirmed = false;
          session.knownCreation = null;
          return review;
        }
      } else {
        await _runGuarded('getOrders', _decisionOrderSnapshot);
      }
      return current() ? createUnknown : stopped;
    }
    if (session.cancellationToVerify case final old?) {
      final checked = await _runGuarded(
        'getOrder',
        () => _decisionOrderDetail(old.tradeNo),
      );
      if (!current()) return stopped;
      if (checked.dataOrNull case final known?) {
        if (known.confirmsCancellationOf(old)) {
          session.cancellationToVerify = null;
          return cancelledWithoutReplacement;
        }
        if (known.status == OrderStatus.completed ||
            known.status == OrderStatus.discounted ||
            old.samePendingQuote(known)) {
          session.cancellationToVerify = null;
        }
      }
      return cancelUnknown;
    }

    // These are independent authenticated reads in the same request-validity
    // scope. Never reuse their evidence across user consent or a write.
    Future<(bool, XbResult<_DecisionOrderSnapshot>)> readIntentEvidence() => (
      _matchesExpectedSubscription(quote.expectedSubscription),
      _runGuarded('getOrders', _decisionOrderSnapshot),
    ).wait;

    final (subscriptionMatches, first) = await readIntentEvidence();
    if (!current()) return stopped;
    if (!subscriptionMatches) return changedSubscription;
    final initial = first.dataOrNull;
    if (initial == null) return review;
    if (!couponCurrent()) return expiredCoupon;
    final snapshotTrades = initial.tradeNos;
    final existing = initial.pending;
    final period = _toSdkPeriod(quote.period);
    var replaced = false;
    if (existing != null) {
      final sameProduct =
          existing.planId == quote.planId && existing.period == period;
      onStage?.call(ConfirmedOrderStage.awaitingConfirmation);
      final consent = await confirm(
        ConfirmedOrderConflict(
          sameSelection: sameProduct,
          quote: quote,
          existingTradeNo: existing.tradeNo,
          existingPlanName: existing.planName ?? '套餐 #${existing.planId}',
          existingPeriod: _toXbPeriod(existing.period!),
          existingPayableCents: existing.payableCents!,
          existingBalanceCents: existing.balanceCents ?? 0,
          existingAppliedSurplusCents: existing.appliedSurplusCents,
        ),
      );
      if (!current() || !consent) return stopped;
      onStage?.call(ConfirmedOrderStage.checking);
      final (subscriptionStillMatches, second) = await readIntentEvidence();
      if (!current()) return stopped;
      if (!subscriptionStillMatches) return changedSubscription;
      final checkedAgain = second.dataOrNull;
      final latest = checkedAgain?.pending;
      if (latest == null || !existing.samePendingQuote(latest)) return review;
      snapshotTrades.addAll(checkedAgain!.tradeNos);
      if (!couponCurrent()) return expiredCoupon;

      if (!await quoteStillAvailable()) return changedQuote;
      if (!current()) return stopped;
      if (!couponCurrent()) return expiredCoupon;
      session.cancellationToVerify = existing;
      final cancel = await _runGuarded(
        'cancelOrder',
        () {
          onStage?.call(ConfirmedOrderStage.cancelling);
          return _sdk.order.cancelOrder(existing.tradeNo);
        },
      );
      if (!current()) return stopped;
      onStage?.call(ConfirmedOrderStage.checkingCancellation);
      final cancelled = await _runGuarded(
        'getOrder',
        () => _decisionOrderDetail(existing.tradeNo),
      );
      if (!current()) return stopped;
      if (cancelled.dataOrNull?.confirmsCancellationOf(existing) != true) {
        return cancelUnknown;
      }
      session.cancellationToVerify = null;
      if (cancel.dataOrNull != true) return cancelledWithoutReplacement;
      replaced = true;

      onStage?.call(ConfirmedOrderStage.checking);
      final (subscriptionAfterCancel, afterCancel) = await readIntentEvidence();
      if (!current()) return stopped;
      final after = afterCancel.dataOrNull;
      if (!subscriptionAfterCancel ||
          after == null ||
          after.pending != null ||
          !couponCurrent()) {
        return cancelledWithoutReplacement;
      }
      snapshotTrades.addAll(after.tradeNos);
    }

    if (!current()) return stopped;
    if (!couponCurrent()) return expiredCoupon;
    if (!await quoteStillAvailable()) {
      return replaced ? cancelledWithoutReplacement : changedQuote;
    }
    if (!current()) return stopped;
    if (!couponCurrent()) return expiredCoupon;
    session.createUnconfirmed = true;
    final creation = await _runGuarded('createOrder', () async {
      final no = await _withKnownWriteRejection(
        () {
          onStage?.call(ConfirmedOrderStage.creating);
          return _sdk.order.createOrder(
            quote.planId,
            period.value,
            couponCode: quote.couponCode,
          );
        },
      );
      if (snapshotTrades.contains(no)) _unknownOrderResponse();
      return _decisionTradeNo(no) ?? _unknownOrderResponse();
    });
    if (creation case XbSuccess<String>(:final data)) {
      session.knownCreation = (
        tradeNo: data,
        planId: quote.planId,
        period: period,
      );
    }
    if (creation case XbFailure<String>(:final error)
        when error is XbBusiness ||
            error is XbUnauthorized ||
            error is XbNetwork && error.kind == NetworkErrorKind.cancelled) {
      session.createUnconfirmed = false;
      if (!current()) return stopped;
      if (replaced) {
        return XbFailure(
          XbUnconfirmed('createOrder', '旧单已取消，新单未创建。${error.message}'),
        );
      }
      return XbFailure(error);
    }
    if (!current()) return stopped;
    onStage?.call(ConfirmedOrderStage.verifying);
    if (creation case XbSuccess<String>(:final data)) {
      final checked = await _runGuarded(
        'getOrder',
        () => _decisionOrderDetail(data),
      );
      if (!current()) return stopped;
      final created = checked.dataOrNull;
      if (created != null &&
          created.complete &&
          created.planId == quote.planId &&
          created.period == period) {
        session.createUnconfirmed = false;
        session.knownCreation = null;
        return created.status == OrderStatus.pending
            ? XbSuccess(data)
            : const XbFailure(
                XbUnconfirmed('createOrder', '新订单已记录，请核对它的最新状态。'),
              );
      }
    } else {
      // No identifier was returned. Refresh without selecting by date, plan,
      // or amount; do not infer failure from an empty response.
      await _runGuarded('getOrders', _decisionOrderSnapshot);
    }
    return current() ? createUnknown : stopped;
  }
}
