import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:flutter_xboard_sdk/src/core/auth/memory_token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';

void main() {
  test('list preserves unknown wire fields, strict detail fails, disabled channels are excluded', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    final row = {'trade_no':'R-01','plan_id':7,'status':99,'period':'future_period','total_amount':1250};
    server.listen((r) async {
      requests.add(r.method);
      final data = r.uri.path.endsWith('getPaymentMethod') ? [
        {'id':3,'name':'停用','is_available':false}, {'id':4,'name':'可用'},
      ] : r.uri.path.endsWith('/fetch') ? [row] : row;
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({'status':'success','data':data}));
      await r.response.close();
    });
    final instance = sdk.XBoardSDK.instance;
    await instance.initialize('http://127.0.0.1:${server.port}', customStorage: MemoryTokenStorage());
    addTearDown(instance.dispose);
    final service = XboardServiceImpl(sdk:instance);
    final summary = (await service.getOrders(forceRefresh:true)).dataOrNull!.items.single;
    expect(summary.status, isNull);
    expect(summary.period, isNull);
    expect((await service.getOrder('R-01')).errorOrNull, isNotNull);
    expect((await service.getPaymentMethods()).dataOrNull!.map((m) => m.id), ['4']);
    expect(requests, everyElement('GET'));
  });
  test('fractional raw status and absent total remain unknown; explicit zero stays payable', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final calls = <String>[];
    final common = {'plan_id': 7, 'period': 'month_price', 'status': 0};
    final rows = [
      {...common, 'trade_no':'F', 'status':0.5, 'total_amount':100},
      {...common, 'trade_no':'M'},
      {...common, 'trade_no':'Z', 'total_amount':0},
    ];
    server.listen((r) async {
      calls.add(r.method);
      final data = r.uri.path.endsWith('/fetch') ? rows : rows.singleWhere((o) => o['trade_no'] == r.uri.queryParameters['trade_no']);
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({'status':'success', 'data':data}));
      await r.response.close();
    });
    final instance = sdk.XBoardSDK.instance;
    await instance.initialize('http://127.0.0.1:${server.port}', customStorage: MemoryTokenStorage());
    addTearDown(instance.dispose);
    final service = XboardServiceImpl(sdk:instance);
    final items = (await service.getOrders(forceRefresh:true)).dataOrNull!.items;
    expect(items.map((o) => o.status), [null, XbOrderStatus.pending, XbOrderStatus.pending]);
    expect(items.map((o) => o.totalAmountYuan), [1.0, null, 0.0]);
    expect((await service.getOrder('F')).errorOrNull, isNotNull);
    expect((await service.getOrder('M')).errorOrNull, isNotNull);
    expect((await service.getOrder('Z')).dataOrNull?.summary.totalAmountYuan, 0.0);
    expect(calls, everyElement('GET'));
  });
  test('wire fees reach Flutter in yuan without losing sign or channel type', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((r) async {
      requests.add('${r.method} ${r.uri.path}');
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({'status':'success','data':[
        {'id':1,'name':'渠道一','payment':'AlipayF2F','handling_fee_fixed':100,'handling_fee_percent':'0.5'},
        {'id':2,'name':'渠道二','payment':'Other','handling_fee_fixed':'-100'},
        {'id':3,'name':'渠道三'},
      ]}));
      await r.response.close();
    });
    final instance = sdk.XBoardSDK.instance;
    await instance.initialize('http://127.0.0.1:${server.port}', customStorage: MemoryTokenStorage());
    addTearDown(instance.dispose);
    final methods = (await XboardServiceImpl(sdk:instance).getPaymentMethods()).dataOrNull!;
    expect(methods.map((m)=>m.feeFixedYuan), [1.0,-1.0,0.0]);
    expect(methods.first.feePercent,0.5);
    expect(methods.first.paymentMethod,'AlipayF2F');
    expect(methods.first.id,'1');
    expect(requests,['GET /api/v1/user/order/getPaymentMethod']);
  });
  for (final brand in ['omo', 'ds']) {
    for (final variant in [
      'create',
      'checkout',
      'cancel',
      'createRejected',
      'checkoutRejected',
      'cancelRejected',
    ]) {
      final rejected = variant.endsWith('Rejected');
      final action = variant.replaceAll('Rejected', '');
      test(
        '$brand $variant sends one POST; only confirmation GET may change API',
        () async {
          SharedPreferences.setMockInitialValues({});
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <String>[];
          server.listen((r) async {
            seen.add('${r.method} ${r.uri.path}');
            final isPreflight = action != 'create' &&
                r.method == 'GET' &&
                r.uri.path.endsWith('/order/detail') &&
                !seen.any((request) => request.startsWith('POST '));
            await r.drain<void>();
            if (rejected && r.method == 'POST') {
              r.response.headers.contentType = ContentType.json;
              r.response.write(
                jsonEncode({
                  'status': 'fail',
                  'message': 'fixture rejection',
                  'data': false,
                }),
              );
            } else if (r.method == 'POST' ||
                (r.uri.path.startsWith('/$brand/a/') && !isPreflight)) {
              r.response.statusCode = 405;
              r.response.write('<html>fixture</html>');
            } else {
              r.response.headers.contentType = ContentType.json;
              r.response.write(
                jsonEncode({
                  'status': 'success',
                  'data': action == 'create'
                      ? []
                      : {
                          'trade_no': 'T',
                          'plan_id': 1,
                          'total_amount': 100,
                          'period': 'month_price',
                           'status': isPreflight ? 0 : action == 'cancel' ? 2 : 3,
                        },
                }),
              );
            }
            await r.response.close();
          });
          final origin = 'http://127.0.0.1:${server.port}/$brand';
          final instance = sdk.XBoardSDK.instance;
          await instance.initialize(
            '$origin/a',
            customStorage: MemoryTokenStorage(),
          );
          addTearDown(instance.dispose);
          instance.httpService.configureEndpointRecovery(
            candidates: () => ['$origin/a', '$origin/b'],
            onSuccess: (_) {},
          );
          final service = XboardServiceImpl(sdk: instance);
          final result = switch (action) {
            'create' => await service.createOrder(1, XbPlanPeriod.monthly),
            'checkout' => await service.checkout('T', 'pay'),
            _ => await service.cancelOrder('T'),
          };
          if (rejected) {
            expect((result as XbFailure).error, isA<XbBusiness>());
          } else if (action == 'create') {
            expect((result as XbFailure).error, isA<XbUnconfirmed>());
          } else {
            expect(result, isA<XbSuccess>());
          }
          expect(seen.where((s) => s.startsWith('POST ')).length, 1);
          expect(
            seen.where((s) => s.startsWith('GET ')).length,
             (action == 'create' ? 0 : 1) + (rejected ? 0 : 2),
          );
          expect(seen.any((s) => s.startsWith('POST /$brand/b/')), isFalse);
        },
      );
    }
  }
}
