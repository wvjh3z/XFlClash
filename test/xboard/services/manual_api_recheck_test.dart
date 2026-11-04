import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';

void main() {
  test(
    'manual probe uses guest GET, no credentials, rejects HTML success',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            requests.add(o);
            h.resolve(
              Response(
                requestOptions: o,
                statusCode: 200,
                data: o.uri.host == 'good.test'
                    ? {'data': {}}
                    : '<html>blocked</html>',
              ),
            );
          },
        ),
      );
      final c = EndpointRaceController(dio: dio);
      c.seedEndpoints([
        const BootstrapEndpoint(url: 'https://bad.test/prefix'),
        const BootstrapEndpoint(url: 'https://good.test/prefix'),
      ], []);
      expect(await c.recheckApi(current: () => true), isTrue);
      expect(c.currentApiEndpoint, 'https://good.test/prefix');
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.method, 'GET');
        expect(request.path, endsWith('/prefix/api/v1/guest/comm/config'));
        expect(request.data, isNull);
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );
      }
      c.dispose();
      dio.close();
    },
  );
  for (final brand in ['brand_a', 'brand_b']) {
    for (final invalidation in ['owner', 'network', 'candidates']) {
      for (final oldFirst in [true, false]) {
        test(
          '$brand round replacement $invalidation oldFirst=$oldFirst',
          () async {
            final probes = [Completer<bool>(), Completer<bool>()];
            var calls = 0;
            var owner = true;
            final switched = <String>[];
            final c = EndpointRaceController(
              probe: (_) => probes[calls++].future,
              onApiSwitch: switched.add,
            );
            c.seedEndpoints([
              const BootstrapEndpoint(url: 'https://a.test'),
            ], []);
            final old = c.recheckApi(current: () => owner);
            if (invalidation == 'owner') {
              owner = false;
            }
            if (invalidation == 'network') {
              c.networkChanged(rerace: false);
            }
            if (invalidation == 'candidates') {
              c.seedEndpoints([
                const BootstrapEndpoint(url: 'https://b.test'),
              ], []);
            }
            final next = c.recheckApi(current: () => true);
            expect(calls, 2);
            if (oldFirst) {
              probes[0].complete(true);
              expect(await old, isNull);
              expect(await c.recheckApi(current: () => true), isNull);
              expect(calls, 2);
              expect(switched, isEmpty);
              probes[1].complete(true);
              expect(await next, isTrue);
            } else {
              probes[1].complete(true);
              expect(await next, isTrue);
              probes[0].complete(true);
              expect(await old, isNull);
            }
            expect(switched, [
              invalidation == 'candidates'
                  ? 'https://b.test'
                  : 'https://a.test',
            ]);
            c.dispose();
          },
        );
      }
    }

    for (final change in [
      'none',
      'network',
      'candidates',
      'disposed',
      'owner',
      'timeout',
    ]) {
      test('$brand manual recheck $change', () async {
        final probe = Completer<bool>();
        var calls = 0;
        var owner = true;
        final switched = <String>[], reachable = <String>[];
        final c = EndpointRaceController(
          probe: (_) {
            calls++;
            return probe.future;
          },
          onApiSwitch: switched.add,
        );
        c.seedEndpoints([const BootstrapEndpoint(url: 'https://a.test')], []);
        c.apiEndpointAvailable = (_) => false;
        c.onManualApiReachable = reachable.add;
        final pending = c.recheckApi(
          current: () => owner,
          timeout: const Duration(milliseconds: 20),
        );
        expect(await c.recheckApi(current: () => owner), isNull);
        expect(calls, 1);
        if (change == 'network') {
          c.networkChanged(rerace: false);
        }
        if (change == 'candidates') {
          c.seedEndpoints([const BootstrapEndpoint(url: 'https://b.test')], []);
        }
        if (change == 'disposed') {
          c.dispose();
        }
        if (change == 'owner') {
          owner = false;
        }
        if (change == 'timeout') {
          expect(await pending, isFalse);
          probe.complete(true);
          await Future<void>.delayed(Duration.zero);
        } else {
          probe.complete(true);
          expect(await pending, change == 'none' ? isTrue : isNull);
        }
        expect(switched, change == 'none' ? ['https://a.test'] : isEmpty);
        expect(reachable, change == 'none' ? ['https://a.test'] : isEmpty);
        if (change != 'disposed') {
          c.dispose();
        }
      });
    }
    test(
      '$brand all fail preserves selected API; next check recovers',
      () async {
        var ok = true;
        final c = EndpointRaceController(probe: (_) async => ok);
        c.seedEndpoints([const BootstrapEndpoint(url: 'https://a.test')], []);
        expect(await c.recheckApi(current: () => true), isTrue);
        ok = false;
        expect(await c.recheckApi(current: () => true), isFalse);
        expect(c.currentApiEndpoint, 'https://a.test');
        ok = true;
        expect(await c.recheckApi(current: () => true), isTrue);
        c.dispose();
      },
    );
  }
}
