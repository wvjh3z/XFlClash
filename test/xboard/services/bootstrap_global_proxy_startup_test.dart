import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/http.dart';
import 'package:fl_clash/models/models.dart' show PatchClashConfig;
import 'package:fl_clash/providers/app.dart' show runTimeProvider;
import 'package:fl_clash/providers/config.dart' show patchClashConfigProvider;
import 'package:fl_clash/state.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/bootstrap_fetcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '_bootstrap_crypto_helper.dart';

void main() {
  test(
    'Bootstrap uses the running global proxy before attach completes',
    () async {
      final origin = await _BootstrapServer.start(
        'https://direct.example.invalid',
      );
      addTearDown(origin.close);
      final proxy = await _BootstrapServer.start(
        'https://proxied.example.invalid',
      );
      addTearDown(proxy.close);
      final container = ProviderContainer(
        overrides: [
          patchClashConfigProvider.overrideWithBuild(
            (_, _) => PatchClashConfig(mixedPort: proxy.server.port),
          ),
        ],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      globalState.isAttach = false;
      addTearDown(() => globalState.isAttach = false);
      container.read(runTimeProvider.notifier).value = 0;
      final routing = _LoopbackRoutingOverrides(origin.server.port);
      final target = Uri(
        scheme: 'http',
        host: 'bootstrap.example.invalid',
        port: origin.server.port,
        path: '/config.json',
      );

      await HttpOverrides.runWithHttpOverrides(() async {
        // Use both the production constructor and the actual global proxy policy.
        final fetcher = BootstrapFetcher(
          decryptor: BootstrapDecryptor(aesKey: testAesKey),
        );
        final proxied = await fetcher.fetchRemote([target.toString()]);
        expect(proxied.isSuccess, isTrue);
        expect(proxied.payload!.apiUrls, ['https://proxied.example.invalid']);
        expect(proxy.requests, [target]);
        expect(origin.requests, isEmpty);
        expect(globalState.isAttach, isFalse);

        container.read(runTimeProvider.notifier).value = null;
        final direct = await fetcher.fetchRemote([target.toString()]);
        expect(direct.isSuccess, isTrue);
        expect(direct.payload!.apiUrls, ['https://direct.example.invalid']);
        expect(proxy.requests, [target]);
        expect(origin.requests.map((uri) => uri.path), ['/config.json']);
        expect(globalState.isAttach, isFalse);
      }, routing);

      expect(routing.proxyHosts, ['localhost', null]);
      expect(routing.proxyPorts, [proxy.server.port, null]);
    },
  );
}

/// Keep FlClashHttpOverrides.findProxy intact. Only map socket destinations to
/// local fixtures, so either policy result is observable without external I/O.
class _LoopbackRoutingOverrides extends FlClashHttpOverrides {
  _LoopbackRoutingOverrides(this.originPort);

  final int originPort;
  final proxyHosts = <String?>[];
  final proxyPorts = <int?>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (_, proxyHost, proxyPort) {
      proxyHosts.add(proxyHost);
      proxyPorts.add(proxyPort);
      return Socket.startConnect(
        InternetAddress.loopbackIPv4,
        proxyHost == null ? originPort : proxyPort!,
      );
    };
    return client;
  }
}

class _BootstrapServer {
  _BootstrapServer(this.server);

  final HttpServer server;
  final requests = <Uri>[];

  static Future<_BootstrapServer> start(String apiEndpoint) async {
    final envelope = await validEnvelope(api: [apiEndpoint]);
    final body = utf8.encode(
      jsonEncode({'schema_version': 1, 'encrypted': envelope.encrypted}),
    );
    final fixture = _BootstrapServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen((request) async {
      fixture.requests.add(request.uri);
      await request.drain<void>();
      request.response
        ..headers.contentType = ContentType.json
        ..contentLength = body.length
        ..add(body);
      await request.response.close();
    });
    return fixture;
  }

  Future<void> close() => server.close(force: true);
}
