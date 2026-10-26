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
                r.uri.path.startsWith('/$brand/a/')) {
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
                          'status': action == 'cancel' ? 2 : 3,
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
            rejected ? 0 : 2,
          );
          expect(seen.any((s) => s.startsWith('POST /$brand/b/')), isFalse);
        },
      );
    }
  }
}
