import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:flutter_xboard_sdk/src/core/auth/memory_token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';

void main() {
  for (final brand in ['omo', 'ds']) {
    for (final phase in ['empty', 'queued', 'dispatched']) {
      test('$brand invite recovery boundary $phase', () async {
        SharedPreferences.setMockInitialValues({});
        var saves = 0;
        var visible = false;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) async {
          await r.drain<void>();
          final save = r.uri.path.endsWith('/save');
          if (save) {
            saves++;
            if (phase != 'dispatched') visible = true;
          }
          r.response.headers.contentType = ContentType.json;
          if (save && phase == 'dispatched') {
            r.response.statusCode = 405;
            r.response.write('<html>fixture</html>');
          } else {
            final code = {
              'user_id': 1,
              'code': 'UNUSED',
              'pv': 0,
              'status': false,
              'created_at': 1,
              'updated_at': 1,
            };
            r.response.write(
              jsonEncode({
                'status': 'success',
                'data': save
                    ? true
                    : {
                        'codes': visible ? [code] : [],
                        'stat': [],
                      },
              }),
            );
          }
          await r.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}/$brand';
        final instance = sdk.XBoardSDK.instance;
        await instance.initialize(
          '$base/a',
          customStorage: MemoryTokenStorage(),
        );
        addTearDown(instance.dispose);
        var candidates = phase == 'empty' ? <String>[] : ['$base/a'];
        instance.httpService.configureEndpointRecovery(
          candidates: () => candidates,
          onSuccess: (_) {},
        );
        final began = Completer<void>();
        final release = Completer<void>();
        var gateUsed = false;
        if (phase == 'queued') {
          // Test-only gate exercises the real asynchronous interceptor boundary.
          // ignore: deprecated_member_use
          instance.httpService.dio.interceptors.insert(
            0,
            InterceptorsWrapper(
              onRequest: (o, h) async {
                if (o.path.endsWith('/invite/save') && !gateUsed) {
                  gateUsed = true;
                  began.complete();
                  await release.future;
                }
                h.next(o);
              },
            ),
          );
        }
        final service = XboardServiceImpl(sdk: instance);
        final first = service.generateInviteCode();
        if (phase == 'queued') {
          await began.future.timeout(const Duration(seconds: 5));
          candidates = ['$base/b'];
          instance.httpService.endpointCandidatesChanged();
          release.complete();
        }
        final error = (await first as XbFailure).error;
        if (phase == 'dispatched') {
          expect(error, isA<XbUnconfirmed>());
          expect(saves, 1);
          visible = true;
        } else {
          expect(
            error,
            isA<XbNetwork>().having(
              (e) => e.kind,
              'kind',
              sdk.NetworkErrorKind.cancelled,
            ),
          );
          expect(saves, 0);
          candidates = ['$base/b'];
          instance.httpService.endpointCandidatesChanged();
          instance.httpService.setBaseUrl('$base/b');
        }
        final next = await service.generateInviteCode();
        expect((next as XbSuccess<String>).data, 'UNUSED');
        expect(
          saves,
          1,
        ); // Only definitely unsent attempts may later issue save.
      });
    }
  }
}
