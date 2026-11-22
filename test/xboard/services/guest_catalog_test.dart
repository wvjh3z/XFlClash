import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/guest_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show PlanModel;

class _Transport implements HttpClientAdapter {
  _Transport(this.send);

  final Future<ResponseBody> Function(RequestOptions, Future<void>?) send;
  int calls = 0;
  bool closed = false;

  @override
  void close({bool force = false}) => closed = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? stream,
    Future<void>? cancel,
  ) {
    calls++;
    return send(options, cancel);
  }
}

PlanItem _toClient(PlanModel model) => PlanItem(
  id: model.id,
  name: model.name,
  description: model.content,
  transferEnableGb: model.transferEnable.toInt(),
  prices: [
    if (model.monthPrice case final monthly?)
      PricePlan(period: XbPlanPeriod.monthly, amountYuan: monthly),
  ],
);

Map<String, Object?> _plan({int id = 42, Object? price = 2501}) => {
  'id': id,
  'group_id': 2,
  'name': '公开套餐 $id',
  'content': '<p>真实服务说明</p>',
  'transfer_enable': 180,
  'show': true,
  'sell': true,
  'renew': true,
  'month_price': price,
};

ResponseBody _catalog(List<Object?> plans) =>
    ResponseBody.fromString(jsonEncode({'status': 'success', 'data': plans}), 200);

void main() {
  test('brand prefix and cents are preserved without account headers', () async {
    RequestOptions? request;
    final transport = _Transport((options, _) async {
      request = options;
      return _catalog([
        _plan(),
        {..._plan(id: 8), 'show': false},
        {..._plan(id: 9), 'sell': false},
        {..._plan(id: 10), 'capacity_limit': 'Sold out'},
      ]);
    });
    final result = await loadGuestCatalog(
      'https://brand.example.invalid/tenant/',
      _toClient,
      testTransport: transport,
    );
    expect(request!.method, 'GET');
    expect(
      request!.uri.toString(),
      'https://brand.example.invalid/tenant/api/v1/guest/plan/fetch',
    );
    expect(request!.followRedirects, isFalse);
    final headers = request!.headers.keys.map((key) => key.toLowerCase());
    expect(headers, isNot(contains('authorization')));
    expect(headers, isNot(contains('cookie')));
    final plan = result.dataOrNull!.single;
    expect(plan.id, 42);
    expect(plan.prices.single.amountYuan, 25.01);
    expect(plan.description, '<p>真实服务说明</p>');
    expect(transport.calls, 1);
    expect(transport.closed, isTrue);
  });

  test('redirects and unauthenticated errors are not followed or empty', () async {
    for (final status in [302, 401]) {
      final transport = _Transport((_, _) async => ResponseBody.fromString(
        '{}',
        status,
        headers: {'location': ['https://different.example.invalid/private']},
      ));
      final result = await loadGuestCatalog(
        'https://brand.example.invalid',
        _toClient,
        testTransport: transport,
      );
      expect(result, isA<XbFailure<List<PlanItem>>>());
      expect((result as XbFailure<List<PlanItem>>).error, isA<XbServer>());
      expect(transport.calls, 1);
    }
  });

  test('fails closed for malformed response or invalid raw amount', () async {
    for (final response in [
      ResponseBody.fromString('{"status":"fail","data":[]}', 200),
      ResponseBody.fromString('{"status":"success","data":{}}', 200),
      _catalog([_plan(price: 2501.25)]),
      _catalog([_plan(), _plan()]),
    ]) {
      final result = await loadGuestCatalog(
        'https://brand.example.invalid',
        _toClient,
        testTransport: _Transport((_, _) async => response),
      );
      expect(result, isA<XbFailure<List<PlanItem>>>());
    }
    final empty = await loadGuestCatalog(
      'https://brand.example.invalid',
      _toClient,
      testTransport: _Transport((_, _) async => _catalog([])),
    );
    expect(empty.dataOrNull, isEmpty);
  });

  test('refuses userinfo / non-HTTPS and stops at total deadline', () async {
    final transport = _Transport((_, _) async => _catalog([]));
    for (final base in [
      'https://name:password@brand.example.invalid',
      'http://brand.example.invalid',
      'https://brand.example.invalid?anything=1',
    ]) {
      final result = await loadGuestCatalog(base, _toClient, testTransport: transport);
      expect(result, isA<XbFailure<List<PlanItem>>>());
    }
    expect(transport.calls, 0);
    final pending = Completer<ResponseBody>();
    final slow = _Transport((_, _) => pending.future);
    final result = await loadGuestCatalog(
      'https://brand.example.invalid',
      _toClient,
      testTransport: slow,
      timeout: const Duration(milliseconds: 100),
    );
    expect((result as XbFailure<List<PlanItem>>).error, isA<XbNetwork>());
    expect(slow.closed, isTrue);
    pending.complete(_catalog([]));
  });
}
