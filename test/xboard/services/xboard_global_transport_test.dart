// Production constructors exercise real loopback HTTP through a scoped global
// override. Cryptographic material comes only from the public test helper.
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/bootstrap_fetcher.dart';
import 'package:fl_clash/xboard/services/encrypted_subscription_service.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:test/test.dart';

import '_bootstrap_crypto_helper.dart';

void main() {
  group('production transports inherit the global proxy', () {
    late _TransportServer origin;
    late _TransportServer proxy;

    setUp(() async {
      origin = await _TransportServer.start();
      addTearDown(origin.close);
      proxy = await _TransportServer.start();
      addTearDown(proxy.close);
    });

    test(
      'Bootstrap default Dio fetches and decrypts via proxy then DIRECT',
      () async {
        final target = origin.uri('/config.json');
        final proxyApi = origin.uri('/proxy-api').toString();
        final originApi = origin.uri('/origin-api').toString();
        proxy.body = jsonEncode({
          'schema_version': 1,
          'encrypted': (await validEnvelope(
            api: [proxyApi],
            sub: [proxyApi],
          )).encrypted,
        });
        origin.body = jsonEncode({
          'schema_version': 1,
          'encrypted': (await validEnvelope(
            api: [originApi],
            sub: [originApi],
          )).encrypted,
        });
        var connected = true;
        final observedStates = <bool>[];

        await HttpOverrides.runWithHttpOverrides(
          () async {
            final fetcher = BootstrapFetcher(
              decryptor: BootstrapDecryptor(aesKey: testAesKey),
            );
            final proxied = await fetcher.fetchRemote([target.toString()]);
            expect(proxied.isSuccess, isTrue);
            expect(proxied.payload!.apiUrls, [proxyApi]);
            expect(proxied.winnerUrl, target.toString());

            connected = false;
            final direct = await fetcher.fetchRemote([target.toString()]);
            expect(direct.isSuccess, isTrue);
            expect(direct.payload!.apiUrls, [originApi]);
          },
          _TransportOverrides((_) {
            observedStates.add(connected);
            return connected ? proxy.pac : 'DIRECT';
          }),
        );

        expect(observedStates, [true, false]);
        expect(proxy.requests, [target]);
        expect(origin.requests.map((uri) => uri.path), ['/config.json']);
      },
    );

    test(
      'encrypted subscription default Dio decrypts proxy and DIRECT bodies',
      () async {
        const proxyYaml = 'proxies: []\n# served by global proxy\n';
        const originYaml = 'proxies: []\n# served by origin\n';
        proxy.body = await encryptPayloadRaw(
          proxyYaml,
          aad: kEncryptedSubscriptionAad,
        );
        origin.body = await encryptPayloadRaw(
          originYaml,
          aad: kEncryptedSubscriptionAad,
        );
        final original = origin.uri('/subscribe/test-token');
        final encrypted = origin.uri('/subscribe/encrypted/test-token');
        var connected = true;
        final observedStates = <bool>[];

        await HttpOverrides.runWithHttpOverrides(
          () async {
            final service = EncryptedSubscriptionService(
              decryptor: BootstrapDecryptor(aesKey: testAesKey),
            );
            final proxied = await service.fetch(original.toString());
            expect(proxied.isSuccess, isTrue);
            expect(utf8.decode(proxied.yamlBytes!), proxyYaml);
            expect(proxied.winnerUrl, encrypted.toString());

            connected = false;
            final direct = await service.fetch(original.toString());
            expect(direct.isSuccess, isTrue);
            expect(utf8.decode(direct.yamlBytes!), originYaml);
          },
          _TransportOverrides((_) {
            observedStates.add(connected);
            return connected ? proxy.pac : 'DIRECT';
          }),
        );

        expect(observedStates, [true, false]);
        expect(proxy.requests, [encrypted]);
        expect(origin.requests.map((uri) => uri.path), [encrypted.path]);
      },
    );

    test(
      'default endpoint race probe inherits proxy changes on the same controller',
      () async {
        origin.body = proxy.body = '{"data":{}}';
        final endpoint = origin.uri('').toString();
        var connected = true;
        final observedStates = <bool>[];
        await HttpOverrides.runWithHttpOverrides(
          () async {
            final controller = EndpointRaceController();
            addTearDown(controller.dispose);
            final candidates = [BootstrapEndpoint(url: endpoint)];
            await controller.raceApi(candidates);
            expect(controller.currentApiEndpoint, endpoint);
            expect(proxy.requests, hasLength(1));
            expect(origin.requests, isEmpty);

            connected = false;
            await controller.raceApi(candidates);
            expect(controller.currentApiEndpoint, endpoint);
          },
          _TransportOverrides((_) {
            observedStates.add(connected);
            return connected ? proxy.pac : 'DIRECT';
          }),
        );

        expect(observedStates, [true, false]);
        expect(proxy.requests.single.path, '/api/v1/guest/comm/config');
        expect(origin.requests.single.path, '/api/v1/guest/comm/config');
      },
    );
  });
}

class _TransportOverrides extends HttpOverrides {
  _TransportOverrides(this.resolve);

  final String Function(Uri) resolve;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = resolve;
}

class _TransportServer {
  _TransportServer(this.server);

  final HttpServer server;
  final requests = <Uri>[];
  String body = '';

  Uri uri(String path) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path);

  String get pac => 'PROXY 127.0.0.1:${server.port}';

  static Future<_TransportServer> start() async {
    final local = _TransportServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    local.server.listen((request) async {
      local.requests.add(request.uri);
      await request.drain<void>();
      final bytes = utf8.encode(local.body);
      request.response
        ..headers.contentType = ContentType.json
        ..persistentConnection = true
        ..contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    return local;
  }

  Future<void> close() => server.close(force: true);
}
