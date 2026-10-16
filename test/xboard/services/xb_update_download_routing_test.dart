// Native HTTP routing checks for the shared release Dio factory. Run with
// flutter test; package:test deliberately avoids TestWidgetsFlutterBinding's
// synthetic HTTP 400 client. Every socket and URL stays on IPv4 loopback.
// These tests do not cover HTTPS CONNECT, TLS, or a device's VPN/TUN routing.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/xboard/services/xboard_release_dio.dart';
import 'package:test/test.dart';

const _originBytes = <int>[0, 1, 2, 127, 128, 254, 255];
const _proxyBytes = <int>[255, 0, 128, 13, 10, 42];

void main() {
  group('release Dio native update download routing', () {
    late _RoutingFixture fixture;

    setUp(() async {
      fixture = _RoutingFixture(
        await Directory.systemTemp.createTemp('xb-update-routing-'),
      );
      addTearDown(fixture.close);
    });

    test('default factory inherits the installed global HTTP proxy', () async {
      final origin = await fixture.serve(bytes: _originBytes);
      final proxy = await fixture.serve(bytes: _proxyBytes);
      final target = origin.uri('/bootstrap-or-subscription');

      await HttpOverrides.runWithHttpOverrides(() async {
        final file = await fixture.download(
          fixture.client(),
          target,
          'proxied.bin',
        );
        expect(await file.readAsBytes(), _proxyBytes);
      }, _ProxyOverrides((_) => proxy.pac));

      expect(proxy.requests, [target]);
      expect(origin.requests, isEmpty);
    });

    test('global proxy is used even when origin is reachable', () async {
      final origin = await fixture.serve(bytes: _originBytes);
      final proxy = await fixture.serve(bytes: _proxyBytes);
      final target = origin.uri('/update.bin');
      final resolved = <Uri>[];
      final dio = fixture.client(
        globalProxy: (uri) {
          resolved.add(uri);
          return proxy.pac;
        },
      );

      final file = await fixture.download(dio, target, 'proxy.bin');

      expect(await file.readAsBytes(), _proxyBytes);
      expect(resolved, contains(target));
      expect(proxy.requests, [target]);
      expect(origin.requests, isEmpty);
    });

    test(
      'same Dio observes DIRECT on the next download after disconnect',
      () async {
        final origin = await fixture.serve(bytes: _originBytes);
        final proxy = await fixture.serve(bytes: _proxyBytes);
        final target = origin.uri('/update.bin');
        var connected = true;
        final observedStates = <bool>[];
        final dio = fixture.client(
          globalProxy: (_) {
            observedStates.add(connected);
            return connected ? proxy.pac : 'DIRECT';
          },
        );

        final proxied = await fixture.download(dio, target, 'connected.bin');
        expect(await proxied.readAsBytes(), _proxyBytes);
        expect(proxy.requests, hasLength(1));
        expect(origin.requests, isEmpty);

        // The server permits keep-alive, while the production client must
        // reconsider the global routing state on the next download.
        connected = false;
        final direct = await fixture.download(dio, target, 'disconnected.bin');

        expect(await direct.readAsBytes(), _originBytes);
        expect(observedStates.first, isTrue);
        expect(observedStates.last, isFalse);
        expect(proxy.requests, hasLength(1));
        expect(origin.requests, hasLength(1));
      },
    );

    test(
      'unavailable global proxy fails without adding a DIRECT fallback',
      () async {
        final origin = await fixture.serve(bytes: _originBytes);
        final unavailable = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final refusedPort = unavailable.port;
        await unavailable.close();
        final dio = fixture.client(
          globalProxy: (_) => 'PROXY 127.0.0.1:$refusedPort',
        );

        await expectLater(
          fixture.download(dio, origin.uri('/update.bin'), 'failed.bin'),
          throwsA(isA<DioException>()),
        );

        expect(origin.requests, isEmpty);
        expect(
          await File('${fixture.directory.path}/failed.bin').exists(),
          isFalse,
        );
      },
    );

    test('proxy HTTP 502 fails without silently retrying DIRECT', () async {
      final origin = await fixture.serve(bytes: _originBytes);
      final proxy = await fixture.serve(
        bytes: _proxyBytes,
        statusCode: HttpStatus.badGateway,
      );
      final dio = fixture.client(globalProxy: (_) => proxy.pac);

      await expectLater(
        fixture.download(dio, origin.uri('/update.bin'), 'failed.bin'),
        throwsA(
          isA<DioException>()
              .having(
                (error) => error.type,
                'type',
                DioExceptionType.badResponse,
              )
              .having((error) => error.response?.statusCode, 'statusCode', 502),
        ),
      );

      expect(proxy.requests, hasLength(1));
      expect(origin.requests, isEmpty);
      expect(
        await File('${fixture.directory.path}/failed.bin').exists(),
        isFalse,
      );
    });

    test(
      'redirect resolves the new URI using the latest connection state',
      () async {
        final origin = await fixture.serve(bytes: _originBytes);
        final destination = origin.uri('/redirected/update.bin');
        var connected = true;
        final proxy = await fixture.serve(
          respond: (request) async {
            // Change state while handling the first response, before HttpClient
            // opens the redirect. No second Dio or adapter is constructed.
            connected = false;
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              destination,
            );
            request.response.contentLength = 0;
            await request.response.close();
          },
        );
        final initial = origin.uri('/redirect');
        final resolved = <Uri>[];
        final dio = fixture.client(
          globalProxy: (uri) {
            resolved.add(uri);
            return connected ? proxy.pac : 'DIRECT';
          },
        );

        final file = await fixture.download(dio, initial, 'redirected.bin');

        expect(await file.readAsBytes(), _originBytes);
        expect(resolved, containsAllInOrder([initial, destination]));
        expect(proxy.requests, [initial]);
        expect(origin.requests.map((uri) => uri.path), [destination.path]);
      },
    );
  });
}

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this.resolve);

  final String Function(Uri) resolve;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = resolve;
}

class _LocalServer {
  _LocalServer(this.server);

  final HttpServer server;
  final requests = <Uri>[];

  Uri uri(String path) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path);

  String get pac => 'PROXY 127.0.0.1:${server.port}';
}

class _RoutingFixture {
  _RoutingFixture(this.directory);

  final Directory directory;
  final _servers = <_LocalServer>[];
  final _clients = <Dio>[];
  final _overrides = <Dio, HttpOverrides>{};

  Future<_LocalServer> serve({
    List<int> bytes = const [],
    int statusCode = HttpStatus.ok,
    FutureOr<void> Function(HttpRequest)? respond,
  }) async {
    final local = _LocalServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    _servers.add(local);
    local.server.listen((request) async {
      local.requests.add(request.uri);
      await request.drain<void>();
      if (respond != null) {
        await respond(request);
      } else {
        request.response
          ..statusCode = statusCode
          ..persistentConnection = true
          ..contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      }
    });
    return local;
  }

  Dio client({String Function(Uri)? globalProxy}) {
    final dio = buildReleasedIsolatedDio(timeout: const Duration(seconds: 3));
    if (globalProxy != null) _overrides[dio] = _ProxyOverrides(globalProxy);
    _clients.add(dio);
    return dio;
  }

  Future<File> download(Dio dio, Uri uri, String name) async {
    final file = File('${directory.path}/$name');
    final overrides = _overrides[dio];
    if (overrides == null) {
      await dio.download(uri.toString(), file.path);
    } else {
      // Scope the override around lazy native client creation and I/O so
      // this exercises inherited routing.
      await HttpOverrides.runWithHttpOverrides(
        () => dio.download(uri.toString(), file.path),
        overrides,
      );
    }
    return file;
  }

  Future<void> close() async {
    for (final dio in _clients) {
      dio.close(force: true);
    }
    for (final local in _servers) {
      await local.server.close(force: true);
    }
    await directory.delete(recursive: true);
  }
}
