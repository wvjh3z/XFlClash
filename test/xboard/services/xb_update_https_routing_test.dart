// Real TLS and HTTP CONNECT checks. All servers and socket destinations stay on
// IPv4 loopback. Public localhost TLS material is committed under test/_fixtures;
// no production credentials or external OpenSSL command are used by the tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/xboard/services/xboard_release_dio.dart';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:test/test.dart';

const _bytes = <int>[0, 255, 127, 128, 10, 42];

void main() {
  group('update HTTPS CONNECT routing', () {
    late _HttpsRoutingFixture fixture;

    setUp(() async {
      fixture = await _HttpsRoutingFixture.create();
      addTearDown(fixture.close);
    });

    test(
      'control: persistent HTTPS tunnel can survive a PAC change to DIRECT',
      () async {
        var connected = true;
        final dio = fixture.client(
          globalProxy: (_) => connected ? fixture.pac : 'DIRECT',
          persistentConnection: true,
        );
        final target = fixture.uri('/update.bin');

        await fixture.download(dio, target, 'proxied.bin');
        connected = false;
        await fixture.download(dio, target, 'still-tunneled.bin');

        // Dart pools successful HTTPS CONNECT tunnels under the origin's key.
        // This passing control demonstrates why a dynamic PAC alone is not enough.
        expect(fixture.connectRequests, 1);
        expect(fixture.proxiedRequests, [true, true]);
      },
    );

    test(
      'update configuration does not reuse the proxy tunnel after disconnect',
      () async {
        var connected = true;
        final observedStates = <bool>[];
        final dio = fixture.client(
          globalProxy: (_) {
            observedStates.add(connected);
            return connected ? fixture.pac : 'DIRECT';
          },
        );
        final target = fixture.uri('/update.bin');

        await fixture.download(dio, target, 'proxied.bin');
        connected = false;
        await fixture.download(dio, target, 'direct.bin');

        expect(observedStates, [true, false]);
        expect(fixture.connectRequests, 1);
        expect(fixture.proxiedRequests, [true, false]);
      },
    );

    test(
      'default probe does not reuse CONNECT after global proxy disconnect',
      () async {
        var connected = true;
        final observedStates = <bool>[];
        fixture.onRequest = (request) {
          request.response
            ..headers.contentType = ContentType.json
            ..write('{}');
          return true;
        };
        await HttpOverrides.runWithHttpOverrides(
          () async {
            final controller = EndpointRaceController();
            addTearDown(controller.dispose);
            final endpoint = fixture.uri('').toString();
            final candidates = [BootstrapEndpoint(url: endpoint)];
            await controller.raceApi(candidates);
            expect(controller.currentApiEndpoint, endpoint);

            connected = false;
            await controller.raceApi(candidates);
            expect(controller.currentApiEndpoint, endpoint);
          },
          _ProxyOverrides((_) {
            observedStates.add(connected);
            return connected ? fixture.pac : 'DIRECT';
          }),
        );

        expect(observedStates, [true, false]);
        expect(fixture.connectRequests, 1);
        expect(fixture.proxiedRequests, [true, false]);
      },
    );

    test(
      'HTTPS redirect reads current PAC and closes the preceding tunnel',
      () async {
        var connected = true;
        final resolved = <Uri>[];
        fixture.onRequest = (request) {
          if (request.uri.path != '/redirect') return false;
          connected = false;
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.locationHeader,
              fixture.uri('/update.bin'),
            )
            ..contentLength = 0;
          return true;
        };
        final dio = fixture.client(
          globalProxy: (uri) {
            resolved.add(uri);
            return connected ? fixture.pac : 'DIRECT';
          },
        );

        await fixture.download(dio, fixture.uri('/redirect'), 'redirected.bin');

        expect(resolved, [
          fixture.uri('/redirect'),
          fixture.uri('/update.bin'),
        ]);
        expect(fixture.connectRequests, 1);
        expect(fixture.proxiedRequests, [true, false]);
      },
    );

    test(
      'rejected global proxy CONNECT fails without a DIRECT fallback',
      () async {
        fixture.rejectConnect = true;
        final dio = fixture.client(globalProxy: (_) => fixture.pac);

        await expectLater(
          fixture.download(dio, fixture.uri('/update.bin'), 'failed.bin'),
          throwsA(isA<DioException>()),
        );

        expect(fixture.connectRequests, 1);
        expect(fixture.proxiedRequests, isEmpty);
      },
    );

    test('HTTPS source HTTP 403 does not trigger a DIRECT retry', () async {
      fixture.onRequest = (request) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..contentLength = 0;
        return true;
      };
      final dio = fixture.client(globalProxy: (_) => fixture.pac);

      await expectLater(
        fixture.download(dio, fixture.uri('/forbidden'), 'forbidden.bin'),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'source status',
            HttpStatus.forbidden,
          ),
        ),
      );

      expect(fixture.connectRequests, 1);
      expect(fixture.proxiedRequests, [true]);
    });
  });
}

class _HttpsRoutingFixture {
  _HttpsRoutingFixture(this.directory, this.origin, this.proxy);

  final Directory directory;
  final HttpServer origin;
  final ServerSocket proxy;
  final _clients = <Dio>[];
  final _overrides = <Dio, HttpOverrides>{};
  final _tunnelSockets = <Socket>[];
  final _proxyOriginPorts = <int>{};
  final proxiedRequests = <bool>[];
  int connectRequests = 0;
  bool rejectConnect = false;
  bool Function(HttpRequest request)? onRequest;

  static Future<_HttpsRoutingFixture> create() async {
    final context = SecurityContext()
      ..useCertificateChain('test/_fixtures/update_routing/localhost.crt')
      ..usePrivateKey('test/_fixtures/update_routing/localhost.key');
    final fixture = _HttpsRoutingFixture(
      await Directory.systemTemp.createTemp('xb-update-https-routing-'),
      await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context),
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.origin.listen(fixture._handleOrigin);
    fixture.proxy.listen(fixture._handleProxySocket);
    return fixture;
  }

  Uri uri(String path) =>
      Uri(scheme: 'https', host: '127.0.0.1', port: origin.port, path: path);

  String get pac => 'PROXY 127.0.0.1:${proxy.port}';

  Future<void> _handleOrigin(HttpRequest request) async {
    proxiedRequests.add(
      _proxyOriginPorts.contains(request.connectionInfo!.remotePort),
    );
    await request.drain<void>();
    if (onRequest?.call(request) != true) {
      request.response
        ..persistentConnection = true
        ..contentLength = _bytes.length
        ..add(_bytes);
    }
    await request.response.close();
  }

  void _handleProxySocket(Socket downstream) {
    _tunnelSockets.add(downstream);
    final header = <int>[];
    Socket? upstream;
    bool headersComplete = false;
    late StreamSubscription<List<int>> subscription;

    void closeTunnel() {
      downstream.destroy();
      upstream?.destroy();
    }

    Future<void> openTunnel(List<int> buffered) async {
      try {
        // HttpServer's URI parser rejects CONNECT's numeric authority-form
        // target before emitting a request. Read this small proxy handshake
        // directly; no arbitrary target is ever used as a socket destination.
        final firstLine = ascii.decode(header).split('\r\n').first;
        expect(firstLine, 'CONNECT 127.0.0.1:${origin.port} HTTP/1.1');
        connectRequests++;
        if (rejectConnect) {
          downstream.write(
            'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n'
            'Connection: close\r\n\r\n',
          );
          await downstream.flush();
          closeTunnel();
          return;
        }

        final connected = await Socket.connect(
          InternetAddress.loopbackIPv4,
          origin.port,
        );
        upstream = connected;
        _proxyOriginPorts.add(connected.port);
        _tunnelSockets.add(connected);
        downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        await downstream.flush();
        connected.listen(
          downstream.add,
          onDone: closeTunnel,
          onError: (Object error, StackTrace stack) => closeTunnel(),
          cancelOnError: true,
        );
        if (buffered.isNotEmpty) connected.add(buffered);
        subscription.resume();
      } catch (_) {
        closeTunnel();
        rethrow;
      }
    }

    subscription = downstream.listen(
      (chunk) {
        if (headersComplete) {
          upstream!.add(chunk);
          return;
        }
        header.addAll(chunk);
        expect(header.length, lessThan(16384));
        for (var i = 0; i + 3 < header.length; i++) {
          if (header[i] == 13 &&
              header[i + 1] == 10 &&
              header[i + 2] == 13 &&
              header[i + 3] == 10) {
            headersComplete = true;
            subscription.pause();
            final buffered = header.sublist(i + 4);
            header.removeRange(i + 4, header.length);
            unawaited(openTunnel(buffered));
            return;
          }
        }
      },
      onDone: closeTunnel,
      onError: (Object error, StackTrace stack) => closeTunnel(),
      cancelOnError: true,
    );
  }

  Dio client({
    required String Function(Uri) globalProxy,
    bool? persistentConnection,
  }) {
    final dio = buildReleasedIsolatedDio(timeout: const Duration(seconds: 3));
    _overrides[dio] = _ProxyOverrides(globalProxy);
    // Only the control opts back into pooling. The regression exercises the
    // production factory default so losing that default cannot pass unnoticed.
    if (persistentConnection != null) {
      dio.options.persistentConnection = persistentConnection;
    }
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
    expect(await file.readAsBytes(), _bytes);
    return file;
  }

  Future<void> close() async {
    for (final dio in _clients) {
      dio.close(force: true);
    }
    for (final socket in _tunnelSockets) {
      socket.destroy();
    }
    await proxy.close();
    await origin.close(force: true);
    await directory.delete(recursive: true);
  }
}

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this.resolve);

  final String Function(Uri) resolve;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = resolve
        ..badCertificateCallback = (_, _, _) => true;
}
