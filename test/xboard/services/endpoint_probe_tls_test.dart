import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/services/xboard_release_dio.dart';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';

class _Policy extends HttpOverrides {
  bool allow = false;
  String proxy = 'DIRECT';
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => proxy;
    client.badCertificateCallback = (_, _, _) => allow;
    return client;
  }
}

void main() {
  test(
    'default probe inherits direct/proxy/direct routing with fresh connections',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var originCalls = 0;
      var proxyCalls = 0;
      origin.listen((request) {
        originCalls++;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"data":{}}');
        unawaited(request.response.close());
      });
      proxy.listen((request) {
        proxyCalls++;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"data":{}}');
        unawaited(request.response.close());
      });
      final policy = _Policy();
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          final race = EndpointRaceController();
          try {
            final endpoints = [
              BootstrapEndpoint(url: 'http://127.0.0.1:${origin.port}'),
            ];
            await race.raceApi(endpoints);
            expect(originCalls, 1);
            policy.proxy = 'PROXY 127.0.0.1:${proxy.port}';
            await race.raceApi(endpoints);
            expect(proxyCalls, 1);
            expect(originCalls, 1);
            policy.proxy = 'DIRECT';
            await race.raceApi(endpoints);
            expect(originCalls, 2);
          } finally {
            race.dispose();
          }
        }, policy);
      } finally {
        await origin.close(force: true);
        await proxy.close(force: true);
      }
    },
  );

  for (final brand in ['brand_a', 'brand_b']) {
    test(
      '$brand default probes use business TLS under strict global policy',
      () async {
        final cert = SecurityContext()
          ..useCertificateChain('test/_fixtures/update_routing/localhost.crt')
          ..usePrivateKey('test/_fixtures/update_routing/localhost.key');
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          cert,
        );
        addTearDown(() => server.close(force: true));
        server.listen((request) {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"data":{}}');
          unawaited(request.response.close());
        }, onError: (Object _) {});
        final endpoint = BootstrapEndpoint(
          url: 'https://127.0.0.1:${server.port}',
        );
        final policy = _Policy();
        await HttpOverrides.runWithHttpOverrides(() async {
          final dio = buildReleasedIsolatedDio(
            timeout: const Duration(seconds: 2),
          );
          try {
            expect(
              (await dio.get(
                '${endpoint.url}/api/v1/guest/comm/config',
              )).statusCode,
              200,
            );
          } finally {
            dio.close(force: true);
          }
          final race = EndpointRaceController();
          addTearDown(race.dispose);
          await race.raceApi([endpoint]);
          await race.raceSubscription([endpoint]);
          expect(race.currentApiEndpoint, endpoint.url);
          expect(race.currentSubscriptionEndpoint, endpoint.url);
          final strict = Dio();
          try {
            await expectLater(
              strict.get(endpoint.url),
              throwsA(isA<DioException>()),
            );
          } finally {
            strict.close(force: true);
          }
          policy.allow = true;
          await race.raceApi([endpoint]);
          await race.raceSubscription([endpoint]);
          expect(race.currentApiEndpoint, endpoint.url);
          expect(race.currentSubscriptionEndpoint, endpoint.url);
        }, policy);
      },
    );
  }
}
