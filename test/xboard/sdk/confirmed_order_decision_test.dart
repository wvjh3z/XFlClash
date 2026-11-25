import 'dart:async';

import 'package:fl_clash/xboard/models/confirmed_order.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:flutter_xboard_sdk/src/core/http/http_service.dart';
import 'package:mocktail/mocktail.dart';

import '../../_fixtures/fake_xboard_sdk.dart';

const _quote = ConfirmedOrderQuote(
  planId: 7,
  planName: 'current plan',
  period: XbPlanPeriod.monthly,
  catalogCents: 1000, estimatedCents: 1000,
);
const _fetch = '/api/v1/user/order/fetch';
String _detail(String no) => '/api/v1/user/order/detail?trade_no=$no';

Map<String, dynamic> _success(Object? data) => {'success': true, 'data': data};

Map<String, dynamic> _wireOrder({
  Object? no = 'OLD',
  Object? status = 0,
  Object? plan = 7,
  Object? period = 'month_price',
  Object? amount = 1000,
  Object? balance,
}) => {
  'trade_no': no,
  'status': status,
  'plan_id': plan,
  'period': period,
  'total_amount': amount,
  'balance_amount': balance,
  'plan': {'name': 'previous plan'},
};

class _Http extends Mock implements HttpService {
  static final _scope = Object();

  static bool get inActiveScope =>
      (Zone.current[_scope] as bool Function()?)?.call() ?? false;

  @override
  Future<T> withRequestValidity<T>(
    bool Function() current,
    Future<T> Function() body,
  ) => runZoned(body, zoneValues: {_scope: current});
}

class _Harness {
  _Harness() {
    apis = instance.setupFor(XbScenario.loggedIn);
    when(() => instance.authSession).thenAnswer(
      (_) => sdk.AuthSessionSnapshot(
        revision: revision,
        state: sdk.AuthState.authenticated,
      ),
    );
    when(() => instance.httpService).thenReturn(http);
    when(() => http.getRequest(any())).thenAnswer((invocation) {
      if (!_Http.inActiveScope) throw StateError('request outside active order scope');
      final path = invocation.positionalArguments.single as String;
      if (path == '/api/v1/user/plan/fetch?id=7') {
        calls.add('quote-check');
        return catalogRead(_success({'id': 7, 'renew': renewable, 'month_price': monthPrice}));
      }
      if (path == '/api/v1/user/plan/fetch') {
        calls.add('reset-check');
        return Future.value(_success([{'id': 7, 'renew': false, 'reset_price': resetPrice}]));
      }
      if (path == _fetch) {
        calls.add('fetch');
        return fetch();
      }
      calls.add('detail:${Uri.parse(path).queryParameters['trade_no']}');
      return detail(path);
    });
    when(() => apis.orderApi.cancelOrder('OLD')).thenAnswer((_) {
      if (!_Http.inActiveScope) throw StateError('request outside active order scope');
      calls.add('cancel:OLD');
      return cancel();
    });
    when(
      () => apis.orderApi.createOrder(7, any(), couponCode: any(named: 'couponCode')),
    ).thenAnswer((_) {
      if (!_Http.inActiveScope) throw StateError('request outside active order scope');
      calls.add('create');
      return create();
    });
  }

  final instance = FakeXBoardSDK();
  late final FakeSubApis apis;
  late final service = XboardServiceImpl(sdk: instance);
  final http = _Http();
  final calls = <String>[];
  final conflicts = <ConfirmedOrderConflict>[];
  Object? monthPrice = 1000;
  Object? resetPrice;
  bool renewable = true;
  var revision = 1;
  bool active = true;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) catalogRead =
      (value) async => value;
  Future<Map<String, dynamic>> Function() fetch = () async => _success([]);
  Future<Map<String, dynamic>> Function(String) detail = (path) async =>
      throw StateError('Unexpected detail request');
  Future<bool> Function() cancel = () async =>
      throw StateError('Unexpected cancel request');
  Future<String> Function() create = () async =>
      throw StateError('Unexpected create request');
  Future<bool> Function() accept = () async => true;

  void existing(Map<String, dynamic> row) {
    fetch = () async => _success([row]);
    detail = (_) async => _success(row);
  }

  Future<XbResult<String?>> submit({
    ConfirmedOrderQuote quote = _quote,
    XboardServiceImpl? via,
    void Function(ConfirmedOrderStage stage)? onStage,
  }) => (via ?? service).confirmOrder(
    quote,
    isActive: () => active,
    onStage: onStage,
    confirm: (conflict) {
      calls.add('confirm');
      conflicts.add(conflict);
      return accept();
    },
  );

  void noWrite() {
    verifyNever(() => apis.orderApi.cancelOrder(any()));
    verifyNever(
      () => apis.orderApi.createOrder(
        any(),
        any(),
        couponCode: any(named: 'couponCode'),
      ),
    );
  }
}

void _expectReview(XbResult<String?> result) {
  expect(result.errorOrNull, isA<XbUnconfirmed>());
  expect(result.dataOrNull, isNull);
}

void main() {
  ConfirmedOrderQuote subscriptionQuote() => ConfirmedOrderQuote(
    planId: 7, planName: 'current', period: XbPlanPeriod.monthly,
    catalogCents: 1000, estimatedCents: 1000,
    expectedSubscription: ConfirmedOrderSubscription(planId: 5, totalBytes: 100, expiredAt: null),
  );

  for (final replace in [false, true]) {
    testWidgets('controlled service latency: ${replace ? 'replace' : 'empty'}', (t) async {
      const hop = Duration(milliseconds: 100);
      final h = _Harness();
      var operations = 0;
      var cancelled = false;
      var subscriptions = 0;
      final stages = <ConfirmedOrderStage>[];
      Future<T> readOrWrite<T>(T result) {
        operations++;
        return Future.delayed(hop, () => result);
      }
      when(h.apis.subscriptionApi.getSubscription).thenAnswer((_) {
        subscriptions++;
        return readOrWrite(sdk.SubscriptionModel(planId: 5, transferEnable: 100));
      });
      h.catalogRead = (raw) => readOrWrite(raw);
      h.fetch = () => readOrWrite(_success([
        if (replace) _wireOrder(plan: 5, status: cancelled ? 2 : 0),
      ]));
      h.detail = (path) => readOrWrite(_success(path == _detail('NEW')
          ? _wireOrder(no: 'NEW')
          : _wireOrder(plan: 5, status: cancelled ? 2 : 0)));
      h.cancel = () async {
        if (stages.last != ConfirmedOrderStage.cancelling) throw StateError('missing cancel stage');
        await readOrWrite(true);
        cancelled = true;
        return true;
      };
      h.create = () {
        if (stages.last != ConfirmedOrderStage.creating) throw StateError('missing creation stage');
        return readOrWrite('NEW');
      };
      final start = t.binding.clock.now();
      Duration? elapsed;
      final result = h.submit(quote: subscriptionQuote(), onStage: stages.add).then((value) {
        elapsed = t.binding.clock.now().difference(start);
        return value;
      });
      await t.pump();
      expect(subscriptions, 1);
      expect(h.calls, ['fetch']); // Both started, neither has returned.
      for (var i = 0; i < 15 && elapsed == null; i++) {
        await t.pump(hop);
      }
      expect(elapsed, hop * (replace ? 11 : 4));
      expect(operations, replace ? 14 : 5); // All original wire operations retained.
      expect((await result).dataOrNull, 'NEW');
      expect(stages, [
        ConfirmedOrderStage.checking,
        if (replace) ...[
          ConfirmedOrderStage.awaitingConfirmation, ConfirmedOrderStage.checking,
          ConfirmedOrderStage.cancelling, ConfirmedOrderStage.checkingCancellation,
          ConfirmedOrderStage.checking,
        ],
        ConfirmedOrderStage.creating, ConfirmedOrderStage.verifying,
      ]);
      expect(h.calls.where((call) => call == 'create'), hasLength(1));
      expect(h.calls.where((call) => call == 'cancel:OLD'), hasLength(replace ? 1 : 0));
    });
  }

  for (final stop in ['subscription', 'session', 'orders']) {
    test('completed sibling read cannot authorize a write: $stop', () async {
      final h = _Harness();
      final list = Completer<Map<String, dynamic>>();
      final sub = Completer<sdk.SubscriptionModel>();
      when(h.apis.subscriptionApi.getSubscription).thenAnswer((_) => sub.future);
      h.fetch = () => list.future;
      final stages = <ConfirmedOrderStage>[];
      final pending = h.submit(quote: subscriptionQuote(), onStage: stages.add);
      await Future<void>.delayed(Duration.zero);
      verify(h.apis.subscriptionApi.getSubscription).called(1);
      expect(h.calls, ['fetch']);
      list.complete(stop == 'orders' ? {'success': false} : _success([]));
      await Future<void>.delayed(Duration.zero);
      h.noWrite();
      if (stop == 'session') h.revision++;
      sub.complete(sdk.SubscriptionModel(planId: stop == 'subscription' ? 6 : 5, transferEnable: 100));
      final result = await pending;
      expect(result.dataOrNull, isNull);
      if (stop != 'session') expect(result.isSuccess, isFalse);
      expect(stages, [ConfirmedOrderStage.checking]);
      h.noWrite();
    });
  }

  for (final price in [null, 1200, 'bad', 1000.25, 1000]) {
    test('quoted period revalidated before cancel, including coupon: $price', () async {
      final h = _Harness()..existing(_wireOrder(plan: 8));
      h.accept = () async { h.monthPrice = price; return true; };
      h.cancel = () async { h.existing(_wireOrder(plan: 8,status: 2)); return true; };
      h.create = () async { h.detail = (_) async => _success(_wireOrder(no: 'NEW')); return 'NEW'; };
      final result = await h.submit(quote: const ConfirmedOrderQuote(planId: 7,
        planName: 'current', period: XbPlanPeriod.monthly, catalogCents: 1000, estimatedCents: 800, couponCode: 'SALE'));
      if (price == 1000) { expect(result.dataOrNull, 'NEW'); }
      else { expect(result.errorOrNull, isA<XbBusiness>()); h.noWrite(); }
    });
  }
  test('catalog change after confirmed cancellation blocks creation', () async {
    final h = _Harness()..existing(_wireOrder(plan: 8));
    h.cancel = () async {
      h.monthPrice = 1100;
      h.existing(_wireOrder(plan: 8, status: 2));
      return true;
    };
    final result = await h.submit();
    expect(result.errorOrNull, isA<XbUnconfirmed>());
    expect(h.calls.where((c) => c == 'cancel:OLD'), hasLength(1));
    expect(h.calls, isNot(contains('create')));
  });
  for (final price in [null, 0]) {
    test('reset offer distinguishes absent and zero without using renew flag: $price', () async {
      final h = _Harness()..existing(_wireOrder(plan: 8))..resetPrice = price;
      when(h.apis.subscriptionApi.getSubscription).thenAnswer((_) async =>
          sdk.SubscriptionModel(planId: 7, transferEnable: 100));
      h.cancel = () async { h.existing(_wireOrder(plan: 8, status: 2)); return true; };
      h.create = () async { h.detail = (_) async => _success(_wireOrder(no: 'NEW', period: 'reset_price', amount: 0)); return 'NEW'; };
      final result = await h.submit(quote: ConfirmedOrderQuote(planId: 7, planName: 'reset',
        period: XbPlanPeriod.resetTraffic, catalogCents: 0, estimatedCents: 0,
        expectedSubscription: ConfirmedOrderSubscription(planId: 7, totalBytes: 100, expiredAt: null)));
      if (price == null) { h.noWrite(); expect(result.errorOrNull, isA<XbBusiness>()); }
      else { expect(result.dataOrNull, 'NEW'); }
    });
  }
  for (final enabled in [true, false]) {
    test('verify renewal after dialog, before replacing old order ($enabled)', () async {
      final h = _Harness()..existing(_wireOrder(plan: 8));
      when(h.apis.subscriptionApi.getSubscription).thenAnswer((_) async =>
          sdk.SubscriptionModel(planId: 7, transferEnable: 100));
      h.accept = () async { h.renewable = enabled; return true; };
      h.cancel = () async { h.existing(_wireOrder(plan: 8, status: 2)); return true; };
      h.create = () async { h.detail = (_) async => _success(_wireOrder(no: 'NEW')); return 'NEW'; };
      final result = await h.submit(quote: ConfirmedOrderQuote(planId: 7, planName: 'current',
        period: XbPlanPeriod.monthly, catalogCents: 1000, estimatedCents: 1000,
        expectedSubscription: ConfirmedOrderSubscription(planId: 7, totalBytes: 100, expiredAt: null)));
      expect(h.calls, contains('quote-check'));
      if(enabled) { expect(result.dataOrNull, 'NEW'); } else { h.noWrite(); expect(result.errorOrNull, isA<XbBusiness>()); }
    });
  }

  test('empty complete fetch creates once and uses only the returned number', () async {
    final h = _Harness()
      ..create = (() async => 'NEW')
      ..detail = ((path) async {
        expect(path, _detail('NEW'));
        return _success(_wireOrder(no: 'NEW', amount: 878));
      });
    expect((await h.submit()).dataOrNull, 'NEW');
    expect(h.calls, ['fetch', 'quote-check', 'create', 'detail:NEW']);
    verify(
      () => h.apis.orderApi.createOrder(7, 'month_price', couponCode: null),
    ).called(1);
  });

  test('a matching pending order beyond SDK page 1 requires consent, including zero', () async {
    final h = _Harness();
    h.accept = () async => false;
    final zero = _wireOrder(amount: 0);
    h.fetch = () async => _success([
      for (var i = 0; i < 25; i++) _wireOrder(no: 'history-$i', status: 3),
      zero,
    ]);
    h.detail = (path) async {
      expect(path, _detail('OLD'));
      return _success(zero);
    };
    expect((await h.submit(quote: const ConfirmedOrderQuote(
      planId: 7,
      planName: 'fixture',
      period: XbPlanPeriod.monthly,
      catalogCents: 0, estimatedCents: 0,
    ))).dataOrNull, isNull);
    expect(h.calls, ['fetch', 'detail:OLD', 'confirm']);
    h.noWrite();
  });

  for (final cents in [1000, 2500]) {
    test('same selection ($cents) cancels verified old order before one new order', () async {
      final h = _Harness()..existing(_wireOrder(amount: cents));
      h.cancel = () async { h.existing(_wireOrder(amount: cents, status: 2)); return true; };
      h.create = () async { h.detail = (_) async => _success(_wireOrder(no: 'NEW')); return 'NEW'; };
      expect((await h.submit()).dataOrNull, 'NEW');
      expect(h.conflicts.single.sameSelection, isTrue);
      expect(h.calls, ['fetch','detail:OLD','confirm','fetch','detail:OLD','quote-check',
        'cancel:OLD','detail:OLD','fetch','quote-check','create','detail:NEW']);
    });
  }

  test('same total with a balance deduction is not silently reused', () async {
    final h = _Harness()..existing(_wireOrder(balance: 400));
    h.accept = () async => false;
    expect(await h.submit(), isA<XbSuccess<String?>>());
    expect(h.conflicts.single.sameSelection, isTrue);
    h.noWrite();
  });

  test('balance 600 and no plan surplus: never infer credit from a price difference', () async {
    final h = _Harness()..existing({..._wireOrder(amount: 2400, balance: 600), 'surplus_amount': 0});
    h.accept = () async => false;
    await h.submit();
    final conflict = h.conflicts.single;
    expect(conflict.existingPayableCents, 2400);
    expect(conflict.quote.estimatedCents, 1000);
    expect(conflict.existingBalanceCents, 600);
    expect(conflict.existingAppliedSurplusCents, 0);
    expect(conflict.existingCreditCents, 600);
    h.noWrite();
  });

  test('same combined credits but changed source invalidates replacement consent', () async {
    final h = _Harness()..existing({..._wireOrder(plan: 5, balance: 600), 'surplus_amount': 0});
    h.accept = () async {
      h.existing({..._wireOrder(plan: 5, balance: 0), 'surplus_amount': 600});
      return true;
    };
    _expectReview(await h.submit());
    h.noWrite();
  });

  test('missing list fields can be filled by exact detail only', () async {
    final h = _Harness()
      ..existing(_wireOrder(status: null, plan: null, period: null, amount: null))
      ..detail = ((_) async => _success(_wireOrder()));
    h.accept = () async => false;
    expect((await h.submit()).dataOrNull, isNull);
    expect(h.conflicts.single.existingTradeNo, 'OLD');
    h.noWrite();
  });

  for (final credit in <int?>[null, 0, 700]) {
    test('old order confirmation distinguishes applied value from excess ($credit)', () async {
      final row = {..._wireOrder(amount: 0), 'surplus_amount': 2000,
        if (credit != null) 'surplus_credit': credit};
      final h = _Harness()..existing(row)..accept = (() async => false);
      await h.submit();
      expect(h.conflicts.single.existingBalanceCents, 0);
      expect(h.conflicts.single.existingAppliedSurplusCents, credit == null ? null : 2000 - credit);
      expect(h.conflicts.single.existingCreditCents, credit == null ? null : 2000 - credit);
      h.noWrite();
    });
  }

  test('changed excess credit invalidates consent even when old total remains zero', () async {
    final row = {..._wireOrder(amount: 0, plan: 8), 'surplus_amount': 2000, 'surplus_credit': 700};
    final h = _Harness()..existing(row);
    h.accept = () async {
      h.existing({...row, 'surplus_credit': 800});
      return true;
    };
    expect(await h.submit(), isA<XbFailure<String?>>());
    h.noWrite();
  });

  for (final invalid in <Map<String, dynamic>>[
    _wireOrder(status: 0.5),
    _wireOrder(status: 42),
    _wireOrder(status: '0'),
    _wireOrder(plan: 7.9),
    _wireOrder(plan: '7'),
    _wireOrder(plan: 0),
    _wireOrder(period: 'invented-period'),
    _wireOrder(amount: 1000.5),
    _wireOrder(amount: -1),
    _wireOrder(amount: '1000'),
    _wireOrder(no: ''),
    _wireOrder(no: 'OLD&trade_no=OTHER'),
  ]) {
    test('malformed evidence fails closed: $invalid', () async {
      final h = _Harness()..existing(invalid);
      _expectReview(await h.submit());
      expect(h.calls, ['fetch']);
      h.noWrite();
    });
  }

  for (final invalid in <Map<String, dynamic>>[
    {'success': false, 'data': []},
    {'success': true, 'data': {}},
    {'success': true, 'data': [], 'total': 1},
    {'success': true, 'data': [], 'total': '0'},
    {'success': true, 'data': [], 'current_page': 1},
    _success([_wireOrder(), _wireOrder(no: 'OTHER')]),
    _success([_wireOrder(), _wireOrder()]),
    _success([_wireOrder(status: 1)]),
  ]) {
    test('unsafe or incomplete snapshot fails closed: $invalid', () async {
      final h = _Harness()
        ..fetch = (() async => invalid)
        ..detail = ((path) async => _success(
          _wireOrder(no: Uri.parse(path).queryParameters['trade_no']),
        ));
      _expectReview(await h.submit());
      expect(h.conflicts, isEmpty);
      h.noWrite();
    });
  }

  test('detail with a different trade number is not an existing order', () async {
    final h = _Harness()
      ..existing(_wireOrder())
      ..detail = ((_) async => _success(_wireOrder(no: 'OTHER')));
    _expectReview(await h.submit());
    h.noWrite();
  });

  test('failed fetch never becomes an empty snapshot', () async {
    final h = _Harness()
      ..fetch = (() async => throw sdk.NetworkException('read failed'));
    _expectReview(await h.submit());
    h.noWrite();
  });

  test('returning a previously known number does not confirm a save', () async {
    final h = _Harness()
      ..existing(_wireOrder(no: 'HISTORY', status: 3))
      ..create = (() async => 'HISTORY');
    _expectReview(await h.submit());
    expect(h.calls, ['fetch', 'quote-check', 'create', 'fetch']);
  });

  for (final mode in ['decline', 'paid', 'new-price', 'account', 'page']) {
    test('$mode during replacement confirmation has no writes', () async {
      final h = _Harness()..existing(_wireOrder(plan: 5));
      h.accept = () async {
        switch (mode) {
          case 'decline':
            return false;
          case 'paid':
            h.existing(_wireOrder(plan: 5, status: 3));
          case 'new-price':
            h.existing(_wireOrder(plan: 5, amount: 2000));
          case 'account':
            h.revision++;
          case 'page':
            h.active = false;
        }
        return true;
      };
      final result = await h.submit();
      expect(result.dataOrNull, isNull);
      if (mode == 'paid' || mode == 'new-price') _expectReview(result);
      expect(h.conflicts.single.sameSelection, isFalse);
      h.noWrite();
    });
  }

  test('replace requires confirmed cancellation before exactly one save', () async {
    final h = _Harness()..existing(_wireOrder(plan: 5));
    h.cancel = () async {
      h.existing(_wireOrder(plan: 5, status: 2));
      return true;
    };
    h.create = () async {
      h.detail = (_) async => _success(_wireOrder(no: 'NEW', amount: 900));
      return 'NEW';
    };
    expect((await h.submit()).dataOrNull, 'NEW');
    expect(h.calls, [
      'fetch', 'detail:OLD', 'confirm', 'fetch', 'detail:OLD',
      'quote-check', 'cancel:OLD', 'detail:OLD', 'fetch', 'quote-check', 'create', 'detail:NEW',
    ]);
  });

  for (final afterCancel in [false, true]) {
    test('subscription changed ${afterCancel ? 'after cancel' : 'in dialog'} blocks save', () async {
      final h = _Harness()..existing(_wireOrder(plan: 5));
      var plan = 5;
      when(h.apis.subscriptionApi.getSubscription).thenAnswer(
        (_) async => sdk.SubscriptionModel(planId: plan, transferEnable: 100),
      );
      h.accept = () async {
        if (!afterCancel) plan = 6;
        return true;
      };
      h.cancel = () async {
        plan = 6;
        h.existing(_wireOrder(plan: 5, status: 2));
        return true;
      };
      final result = await h.submit(quote: ConfirmedOrderQuote(
        planId: _quote.planId,
        planName: _quote.planName,
        period: _quote.period,
        catalogCents: _quote.catalogCents, estimatedCents: _quote.estimatedCents,
        expectedSubscription: ConfirmedOrderSubscription(
          planId: 5,
          totalBytes: 100,
          expiredAt: null,
        ),
      ));
      expect(result.dataOrNull, isNull);
      expect(h.calls.where((call) => call == 'cancel:OLD'), hasLength(afterCancel ? 1 : 0));
      expect(h.calls, isNot(contains('create')));
    });
  }

  for (final mode in ['unknown', 'still-pending', 'paid', 'switch-account']) {
    test('$mode after cancel never creates a replacement', () async {
      final h = _Harness()..existing(_wireOrder(period: 'quarter_price'));
      h.cancel = () async {
        if (mode == 'switch-account') {
          h.revision++;
          return true;
        }
        if (mode == 'unknown') {
          h.existing(_wireOrder(period: 'quarter_price', status: 2));
          throw sdk.NetworkException('lost cancel response');
        }
        if (mode == 'paid') {
          h.existing(_wireOrder(period: 'quarter_price', status: 1));
        }
        return true;
      };
      final result = await h.submit();
      if (mode != 'switch-account') _expectReview(result);
      expect(result.dataOrNull, isNull);
      expect(h.calls.where((e) => e == 'cancel:OLD'), hasLength(1));
      expect(h.calls, isNot(contains('create')));
    });
  }

  test('lost save after a true cancellation only reads, even after service replacement', () async {
    final h = _Harness()..existing(_wireOrder(plan: 5));
    h.cancel = () async {
      h.existing(_wireOrder(plan: 5, status: 2));
      return true;
    };
    h.create = () async => throw sdk.NetworkException('lost creation response');
    _expectReview(await h.submit());
    final before = h.calls.length;
    // Absence is not proof the previous save failed.
    h.fetch = () async => _success([]);
    _expectReview(await h.submit(via: XboardServiceImpl(sdk: h.instance)));
    expect(h.calls.skip(before), ['fetch']);
    expect(h.calls.where((e) => e == 'create'), hasLength(1));
  });

  for (final recoveredStatus in [0, 2, 3]) {
    test('known save with delayed detail recovers read-only: $recoveredStatus', () async {
      final h = _Harness()..create = (() async => 'NEW');
      h.detail = (_) async => throw sdk.NetworkException('not visible yet');
      _expectReview(await h.submit());
      h.detail = (_) async => _success(
        _wireOrder(no: 'NEW', status: recoveredStatus),
      );
      final before = h.calls.length;
      _expectReview(await h.submit());
      expect(h.calls.skip(before), ['detail:NEW']);
      final newReads = h.calls.length;
      h.existing(_wireOrder(no: 'NEW', status: recoveredStatus));
      if (recoveredStatus == 0) {
        h.accept = () async => false;
        expect((await h.submit()).dataOrNull, isNull);
        expect(h.calls.skip(newReads), ['fetch', 'detail:NEW','confirm']);
      } else {
        h.create = () async => throw sdk.ApiException('unavailable', 400);
        expect((await h.submit()).errorOrNull, isA<XbBusiness>());
        expect(h.calls.skip(newReads), ['fetch', 'quote-check', 'create']);
      }
    });
  }

  test('shared order lock blocks another submit or legacy cancel while awaiting confirm', () async {
    final h = _Harness()..existing(_wireOrder(plan: 5));
    final asked = Completer<void>();
    final answer = Completer<bool>();
    h.accept = () {
      asked.complete();
      return answer.future;
    };
    final first = h.submit();
    await asked.future;
    final replacement = XboardServiceImpl(sdk: h.instance);
    expect((await h.submit(via: replacement)).errorOrNull, isA<XbBusiness>());
    expect((await replacement.cancelOrder('OLD')).errorOrNull, isA<XbBusiness>());
    answer.complete(false);
    expect((await first).dataOrNull, isNull);
    expect(h.calls, ['fetch', 'detail:OLD', 'confirm']);
    h.noWrite();
  });
}
