// Exercise the production downloader, not only its Dio factory, using Linux
// host I/O. All requests stay on loopback. Omitting requestLinuxExit stops at
// platform handoff, before chmod, AppImage replacement or process launch.
import 'dart:io';

import 'package:fl_clash/xboard/services/xb_apk_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _originBytes = <int>[0, 1, 2, 127, 128, 254, 255];
const _proxyBytes = <int>[255, 0, 128, 13, 10, 42];
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('Linux downloader native routing to platform handoff', () {
    late Directory temporaryDirectory;
    late _DownloadServer origin;
    late _DownloadServer proxy;
    late List<String> pathCalls;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'xb-downloader-routing-',
      );
      addTearDown(() async {
        await temporaryDirectory.delete(recursive: true);
      });
      origin = await _DownloadServer.start(_originBytes);
      addTearDown(origin.close);
      proxy = await _DownloadServer.start(_proxyBytes);
      addTearDown(proxy.close);
      pathCalls = [];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _pathProviderChannel,
        (call) async {
          pathCalls.add(call.method);
          if (call.method == 'getTemporaryDirectory') {
            return temporaryDirectory.path;
          }
          throw MissingPluginException('Unexpected method ${call.method}');
        },
      );
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _pathProviderChannel,
          null,
        );
      });
    });

    Future<void> verifyDownload({required bool useProxy}) async {
      final resolved = <Uri>[];
      var receivedBytes = 0;
      var totalBytes = 0;
      final target = origin.uri;

      // Scoped override replaces Flutter's synthetic HTTP 400 client with real
      // native sockets for this call without changing global HTTP overrides.
      final result = await HttpOverrides.runWithHttpOverrides(
        () => XbApkDownloader.downloadAndInstall(
          urls: [target.toString()],
          onProgress: (received, total) {
            receivedBytes = received;
            totalBytes = total;
          },
        ),
        _RealHttpOverrides((uri) {
          resolved.add(uri);
          return useProxy ? proxy.pac : 'DIRECT';
        }),
      );

      expect(result, DownloadResult.installFailed);
      expect(pathCalls, ['getTemporaryDirectory']);
      expect(resolved, contains(target));
      expect(proxy.requests, useProxy ? [target] : isEmpty);
      expect(origin.requests, useProxy ? isEmpty : hasLength(1));
      if (!useProxy) {
        expect(origin.requests.single.path, target.path);
      }
      final expectedLength = useProxy
          ? _proxyBytes.length
          : _originBytes.length;
      expect(receivedBytes, expectedLength);
      expect(totalBytes, expectedLength);
      final updateDirectory = Directory('${temporaryDirectory.path}/update');
      expect(await updateDirectory.exists(), isTrue);
      expect(await updateDirectory.list().toList(), isEmpty);
    }

    test(
      'HTTP failure and cancellation do not reach installation; retry recovers',
      () async {
        origin.statusCode = HttpStatus.serviceUnavailable;
        final failed = await HttpOverrides.runWithHttpOverrides(
          () => XbApkDownloader.downloadAndInstall(
            urls: [origin.uri.toString()],
            onProgress: (_, _) {},
          ),
          _RealHttpOverrides((_) => 'DIRECT'),
        );
        expect(failed, DownloadResult.networkError);
        origin.statusCode = HttpStatus.ok;
        final cancellation = CancelToken();
        final cancelled = await HttpOverrides.runWithHttpOverrides(
          () => XbApkDownloader.downloadAndInstall(
            urls: [origin.uri.toString()],
            cancelToken: cancellation,
            onProgress: (_, _) => cancellation.cancel(),
          ),
          _RealHttpOverrides((_) => 'DIRECT'),
        );
        expect(cancelled, DownloadResult.networkError);
        // Failed downloads release the shared gate and remove their task files.
        origin.requests.clear();
        pathCalls.clear();
        await verifyDownload(useProxy: false);
      },
    );

    test(
      'production downloader inherits the global proxy for real download I/O',
      () async {
        await verifyDownload(useProxy: true);
      },
    );

    test(
      'DIRECT downloads from origin and cleans the file after unavailable platform handoff',
      () async {
        await verifyDownload(useProxy: false);
      },
    );
  }, skip: !Platform.isLinux);
}

class _RealHttpOverrides extends HttpOverrides {
  _RealHttpOverrides(this.resolve);

  final String Function(Uri) resolve;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = resolve;
}

class _DownloadServer {
  _DownloadServer(this.server);

  final HttpServer server;
  final requests = <Uri>[];
  int statusCode = HttpStatus.ok;

  Uri get uri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: server.port,
    path: '/update.AppImage',
  );

  String get pac => 'PROXY 127.0.0.1:${server.port}';

  static Future<_DownloadServer> start(List<int> bytes) async {
    final local = _DownloadServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    local.server.listen((request) async {
      local.requests.add(request.uri);
      await request.drain<void>();
      request.response
        ..statusCode = local.statusCode
        ..contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    return local;
  }

  Future<void> close() => server.close(force: true);
}
