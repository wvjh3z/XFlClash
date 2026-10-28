import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/xboard/services/exit_ip_probe.dart';
import 'package:flutter_test/flutter_test.dart';

class _Requests implements HttpClientAdapter {
  final pending = <String, Completer<ResponseBody>>{};
  final cancelled = <String>{};
  int closed = 0;
  final ready = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? body,
    Future<void>? cancel,
  ) {
    final c = Completer<ResponseBody>();
    pending[options.uri.toString()] = c;
    if (pending.length == 7 && !ready.isCompleted) ready.complete();
    cancel?.then((_) => cancelled.add(options.uri.toString()));
    return c.future;
  }

  void answer(String url, Object body, {int status = 200}) {
    pending[url]!.complete(ResponseBody.fromString(jsonEncode(body), status));
  }

  @override
  void close({bool force = false}) {
    closed++;
  }
}

class _Policy extends HttpOverrides {
  String proxy = 'DIRECT';
  bool allow = false;
  int clients = 0;
  int certificateDecisions = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    final client = super.createHttpClient(context);
    client.findProxy = (_) => proxy;
    client.badCertificateCallback = (_, _, _) {
      certificateDecisions++;
      return allow;
    };
    return client;
  }
}

void main() {
  test('legacy source list, schema, IPv4/IPv6 and ten second defaults', () {
    expect(xbLegacyExitIpSources.map((s) => s.url), [
      'https://ipwho.is',
      'https://api.myip.com',
      'https://ipapi.co/json',
      'https://ident.me/json',
      'http://ip-api.com/json',
      'https://api.ip.sb/geoip',
      'https://ipinfo.io/json',
    ]);
    for (final source in xbLegacyExitIpSources) {
      for (final ip in ['203.0.113.2', '2001:db8::1']) {
        final parsed = source.parse({
          source.ipKey: ip,
          source.countryKey: 'hk',
        });
        expect(parsed?.ip, ip);
        expect(parsed?.countryCode, 'HK');
      }
      for (final ip in ['', 'invalid', '999.999.1.1', null]) {
        expect(
          source.parse({source.ipKey: ip, source.countryKey: 'CN'}),
          isNull,
        );
      }
    }
    final probe = XbExitIpProbe();
    expect(probe.timeout, const Duration(seconds: 10));
    probe.cancel();
  });

  test(
    'all seven start together; invalid/HTTP error cannot win; cancel losers',
    () async {
      final transport = _Requests();
      final probe = XbExitIpProbe(dio: Dio()..httpClientAdapter = transport);
      final future = probe.run();
      await transport.ready.future.timeout(const Duration(seconds: 10));
      expect(transport.pending.length, 7);
      transport.answer(xbLegacyExitIpSources[0].url, {'ip': 'invalid'});
      transport.answer(xbLegacyExitIpSources[1].url, {
        'ip': '203.0.113.9',
        'cc': 'US',
      }, status: 403);
      transport.answer(xbLegacyExitIpSources[2].url, {
        'ip': '203.0.113.3',
        'country_code': 'JP',
      });
      expect((await future)?.ip, '203.0.113.3');
      await Future<void>.delayed(Duration.zero);
      expect(transport.closed, 1);
      expect(transport.cancelled.length, 7);
    },
  );

  test(
    'all failures and explicit cancellation settle without old results',
    () async {
      final transport = _Requests();
      final probe = XbExitIpProbe(dio: Dio()..httpClientAdapter = transport);
      final result = probe.run();
      await transport.ready.future.timeout(const Duration(seconds: 10));
      for (final s in xbLegacyExitIpSources) {
        transport.answer(s.url, {'ip': 'invalid'});
      }
      expect(await result, isNull);
      final pending = XbExitIpProbe(
        dio: Dio()..httpClientAdapter = _Requests(),
      );
      final wait = pending.run();
      pending.cancel();
      expect(await wait, isNull);
      expect(await pending.run(), isNull);
    },
  );

  test('malformed and oversized bodies cannot become an IP result', () async {
    for (final body in ['not json', jsonEncode('x' * (64 * 1024 + 1))]) {
      final transport = _Requests();
      final probe = XbExitIpProbe(dio: Dio()..httpClientAdapter = transport);
      final result = probe.run();
      await transport.ready.future.timeout(const Duration(seconds: 10));
      for (final pending in transport.pending.values) {
        pending.complete(ResponseBody.fromString(body, 200));
      }
      expect(await result, isNull);
      expect(transport.closed, 1);
    }
  });

  testWidgets('ten second deadline cancels unresponsive sources', (
    tester,
  ) async {
    final transport = _Requests();
    final probe = XbExitIpProbe(dio: Dio()..httpClientAdapter = transport);
    var settled = false;
    XbExitIpResult? answer;
    unawaited(
      probe.run().then((result) {
        answer = result;
        settled = true;
      }),
    );
    for (var i = 0; i < 20 && transport.pending.length < 7; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(transport.pending.length, 7);
    await tester.pump(const Duration(seconds: 9));
    expect(settled, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(settled, isTrue);
    expect(answer, isNull);
    expect(transport.closed, 1);
  });

  test(
    'new rounds inherit global proxy and return to DIRECT after disconnect',
    () async {
      final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await direct.close(force: true);
        await proxy.close(force: true);
      });
      void respond(HttpRequest request, String ip) {
        request.response.write(jsonEncode({'ip': ip, 'cc': 'HK'}));
        unawaited(request.response.close());
      }

      direct.listen((r) => respond(r, '203.0.113.1'));
      proxy.listen((r) => respond(r, '203.0.113.2'));
      final source = XbExitIpSource(
        'http://127.0.0.1:${direct.port}/ip',
        'ip',
        'cc',
      );
      final policy = _Policy();
      await HttpOverrides.runWithHttpOverrides(() async {
        expect(
          (await XbExitIpProbe(sources: [source]).run())?.ip,
          '203.0.113.1',
        );
        policy.proxy = 'PROXY 127.0.0.1:${proxy.port}';
        expect(
          (await XbExitIpProbe(sources: [source]).run())?.ip,
          '203.0.113.2',
        );
        policy.proxy = 'DIRECT';
        expect(
          (await XbExitIpProbe(sources: [source]).run())?.ip,
          '203.0.113.1',
        );
      }, policy);
      expect(policy.clients, 3);
    },
  );

  test(
    'global certificate rejection and trust both remain effective',
    () async {
      final context = SecurityContext()
        ..useCertificateChain('test/_fixtures/update_routing/localhost.crt')
        ..usePrivateKey('test/_fixtures/update_routing/localhost.key');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.write('{"ip":"203.0.113.4","cc":"HK"}');
        unawaited(request.response.close());
      }, onError: (Object _) {});
      final source = XbExitIpSource(
        'https://127.0.0.1:${server.port}/ip',
        'ip',
        'cc',
      );
      final policy = _Policy();
      await HttpOverrides.runWithHttpOverrides(() async {
        expect(await XbExitIpProbe(sources: [source]).run(), isNull);
        policy.allow = true;
        expect(
          (await XbExitIpProbe(sources: [source]).run())?.ip,
          '203.0.113.4',
        );
      }, policy);
      expect(policy.certificateDecisions, greaterThanOrEqualTo(2));
    },
  );
}
