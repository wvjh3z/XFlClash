import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:flutter_xboard_sdk/src/core/auth/memory_token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';

void main() {
  test(
    'service and real SDK send exact integer cents; invalid inputs never dispatch',
    () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final amounts = <Object?>[];
      server.listen((r) async {
        final raw = await utf8.decoder.bind(r).join();
        if (r.method != 'POST') {
          r.response.headers.contentType = ContentType.json;
          r.response.write('{"data":{}}');
          await r.response.close();
          return;
        }
        final body = jsonDecode(raw) as Map;
        expect(r.uri.path, '/api/v1/user/transfer');
        amounts.add(body['transfer_amount']);
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"status":"success","data":true}');
        await r.response.close();
      });
      final instance = sdk.XBoardSDK.instance;
      await instance.initialize(
        'http://127.0.0.1:${server.port}',
        customStorage: MemoryTokenStorage(),
      );
      addTearDown(instance.dispose);
      final service = XboardServiceImpl(sdk: instance);
      for (final yuan in [0.29, 0.57, 1.13, 2.01, 4.10]) {
        expect(
          await service.transferCommissionToBalance(yuan),
          isA<XbSuccess<bool>>(),
        );
      }
      expect(amounts, [29, 57, 113, 201, 410]);
      for (final bad in [double.nan, double.infinity, -1.0, 0.0, 1.001]) {
        expect(
          await service.transferCommissionToBalance(bad),
          isA<XbFailure<bool>>(),
        );
      }
      for (final badCents in [double.nan, double.infinity, 28.9, -1.0, 0.0]) {
        await expectLater(
          instance.invite.transferCommissionToBalance(badCents),
          throwsA(isA<sdk.ParameterException>()),
        );
      }
      expect(amounts, [29, 57, 113, 201, 410]);
    },
  );
}
