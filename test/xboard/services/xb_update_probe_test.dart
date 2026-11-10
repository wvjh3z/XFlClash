import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/xb_update_probe.dart';
import 'package:fl_clash/xboard/services/xboard_release_dio.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Future<ResponseBody> Function(RequestOptions) reply;
  final requests = <RequestOptions>[];
  int active = 0;
  int maximum = 0;
  int closes = 0;
  int cancellations = 0;
  void Function()? onClose;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    unawaited(cancelFuture?.then<void>((_) { cancellations++; }));
    active++;
    if (active > maximum) maximum = active;
    try { return await reply(options); } finally { active--; }
  }
  @override
  void close({bool force = false}) { closes++; onClose?.call(); }
}

ResponseBody binary([int status = 206]) => ResponseBody.fromBytes(
    [0x4d, 0x5a, 0, 1], status,
    headers: {Headers.contentTypeHeader: ['application/octet-stream']});

void main() {
  for (final size in [102399, 102400, 102401]) {
    test('transport exposes at most102400 bytes before consumer truncation: body=$size', () async {
      final seen = <int>[];
      final adapter = _Adapter((_) async => ResponseBody.fromBytes(
          Uint8List(size)..[0] = 0x4d, 200));
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        // Dio records these bytes after the transport adapter, before the
        // probe consumer can trim its own sample. A +1-byte adapter bug fails.
        options.onReceiveProgress = (received, total) => seen.add(received);
        handler.next(options);
      }));
      final probe = XbUpdateSourceProbe(dio: dio);
      await probe.run(['https://fixture.invalid/binary']);
      expect(seen, isNotEmpty);
      expect(seen.last, size < 102400 ? size : 102400);
      expect(seen, everyElement(lessThanOrEqualTo(102400)));
    });
  }

  test('GET range confirms sources but retains all unconfirmed candidates in order', () async {
    final adapter = _Adapter((o) async => switch (o.uri.path) {
      '/bad' => binary(404),
      '/partial' => binary(),
      '/full' => binary(200),
      '/empty' => ResponseBody.fromBytes([], 206),
      '/html' => ResponseBody.fromString('<html>challenge</html>', 200,
          headers: {Headers.contentTypeHeader: ['text/html']}),
      '/disguised' => ResponseBody.fromString('<html>challenge</html>', 200),
      _ => throw StateError('network unavailable'),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final probe = XbUpdateSourceProbe(dio: dio);
    final urls = ['bad','partial','full','empty','html','disguised','error']
        .map((s) => 'https://fixture.invalid/$s').toList();
    final result = await probe.run([...urls, urls[0]]);
    expect(result, [urls[1],urls[2],urls[0],...urls.skip(3)]);
    expect(adapter.requests.length, 7);
    expect(adapter.maximum, lessThanOrEqualTo(2));
    for (final request in adapter.requests) {
      expect(request.method, 'GET');
      expect(request.responseType, ResponseType.stream);
      expect(request.headers['Range'], 'bytes=0-102399');
      expect(request.headers['Accept-Encoding'], 'identity');
    }
    expect(adapter.closes, 1);
    expect(() => result.add('extra'), throwsUnsupportedError);
    expect(await probe.run(['https://ignored.invalid']), same(result));
  });

  test('200 response ignoring Range is sampled then cancelled, not fully buffered', () async {
    var chunks = 0;
    var cancelled = false;
    const totalChunks = 128;
    Stream<Uint8List> body() async* {
      try {
        for (var i = 0; i < totalChunks; i++) {
          chunks++;
          yield Uint8List(64 * 1024)..[0] = 0x4d;
        }
      } finally { cancelled = true; }
    }
    final adapter = _Adapter((_) async => ResponseBody(body(), 200));
    final probe = XbUpdateSourceProbe(dio: Dio()..httpClientAdapter = adapter);
    final result = await probe.run(['https://fixture.invalid/large']);
    expect(result, ['https://fixture.invalid/large']);
    // Dio/stream adapters may prefetch a chunk before cancellation propagates.
    // The range-ignoring response must stop well before the entire body arrives.
    expect(chunks, lessThan(totalChunks));
    expect(cancelled, isTrue);
    expect(adapter.closes, 1);
  });

  test('whole-round timeout settles callers, stops queue and ignores late replies', () async {
    final replies = <Completer<ResponseBody>>[];
    final started = Completer<void>();
    final adapter = _Adapter((_) {
      final reply = Completer<ResponseBody>();
      replies.add(reply);
      if (replies.length == 2) started.complete();
      return reply.future;
    });
    final probe = XbUpdateSourceProbe(dio: Dio()..httpClientAdapter = adapter,
        timeout: const Duration(milliseconds: 200));
    const urls = ['https://a.invalid/file','https://b.invalid/file','https://c.invalid/file'];
    final flight = probe.run(urls);
    await started.future.timeout(const Duration(seconds: 2));
    expect(adapter.requests.length, 2);
    final result = await flight.timeout(const Duration(seconds: 2));
    expect(result, urls);
    expect(adapter.closes, 1);
    for (final reply in replies) { reply.complete(binary()); }
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests.length, 2);
    expect(adapter.cancellations, 2, reason: 'each in-flight adapter must receive cancellation');
    expect(result, urls);
  });

  test('bounded concurrency refills slots without changing preference order', () async {
    final replies = <Completer<ResponseBody>>[];
    final entered = List.generate(6, (_) => Completer<void>());
    final adapter = _Adapter((_) {
      final reply = Completer<ResponseBody>();
      replies.add(reply);
      entered[replies.length - 1].complete();
      return reply.future;
    });
    final probe = XbUpdateSourceProbe(dio: Dio()..httpClientAdapter = adapter);
    final urls = List.generate(6, (i) => 'https://fixture.invalid/$i');
    final flight = probe.run(urls);
    await entered[1].future.timeout(const Duration(seconds: 2));
    expect(replies.length, 2);
    for (final i in [1, 0, 2, 3, 4, 5]) {
      await entered[i].future.timeout(const Duration(seconds: 2));
      replies[i].complete(binary());
    }
    expect(await flight, urls);
    expect(adapter.maximum, 2);
  });

  test('cancel before starting never requests a source', () async {
    final adapter = _Adapter((_) async => binary());
    final probe = XbUpdateSourceProbe(dio: Dio()..httpClientAdapter = adapter);
    probe.cancel();
    expect(await probe.run(['https://fixture.invalid/file']), isEmpty);
    expect(adapter.requests, isEmpty);
    expect(adapter.closes, 1);
  });

  test('explicit cancellation reaches a hanging transport and settles the caller', () async {
    final listening = Completer<void>();
    final cancelled = Completer<void>();
    final body = StreamController<Uint8List>(
      onListen: () => listening.complete(),
      onCancel: () { if (!cancelled.isCompleted) cancelled.complete(); },
    );
    final adapter = _Adapter((_) async => ResponseBody(body.stream, 206));
    // A failing transport can emit a socket error while force-close is in flight.
    // Keep this as a safety assertion; do not swallow an unhandled zone error.
    adapter.onClose = () {
      body.addError(const SocketException('controlled transport closed'));
      unawaited(body.close());
    };
    final probe = XbUpdateSourceProbe(dio: Dio()..httpClientAdapter = adapter);
    try {
      final pending = probe.run(['https://fixture.invalid/hanging']);
      await listening.future.timeout(const Duration(seconds: 2));
      probe.cancel();
      expect(await pending, ['https://fixture.invalid/hanging']);
      await cancelled.future.timeout(const Duration(seconds: 2));
      expect(adapter.cancellations, 1);
      expect(adapter.closes, 1);
    } finally {
      probe.cancel();
      await body.close();
    }
  });

  test('cancellation directly unsubscribes a hanging body even with a no-op adapter close', () async {
    final listening = Completer<void>();
    final cancelled = Completer<void>();
    final body = StreamController<Uint8List>(
      onListen: () => listening.complete(),
      onCancel: () { if (!cancelled.isCompleted) cancelled.complete(); },
    );
    final adapter = _Adapter((_) async => ResponseBody(body.stream, 206));
    final probe = XbUpdateSourceProbe(dio: Dio()..httpClientAdapter = adapter);
    try {
      final pending = probe.run(['https://fixture.invalid/hanging']);
      await listening.future.timeout(const Duration(seconds: 2));
      probe.cancel();
      expect(await pending, ['https://fixture.invalid/hanging']);
      await cancelled.future.timeout(const Duration(seconds: 2));
      expect(adapter.cancellations, 1);
    } finally {
      probe.cancel();
      await body.close();
    }
  });

  test('active body errors remain unconfirmed instead of being marked available', () async {
    final adapter = _Adapter((options) async => options.uri.path == '/broken'
        ? ResponseBody(Stream<Uint8List>.error(const SocketException('active failure')), 206)
        : binary());
    final probe = XbUpdateSourceProbe(dio: Dio()..httpClientAdapter = adapter);
    expect(await probe.run(['https://fixture.invalid/broken','https://fixture.invalid/good']),
        ['https://fixture.invalid/good','https://fixture.invalid/broken']);
  });

  test('control: direct Dio safely cancels the same faulting hanging response', () async {
    final listening = Completer<void>();
    final cancelled = Completer<void>();
    final body = StreamController<Uint8List>(
      onListen: () => listening.complete(),
      onCancel: () { if (!cancelled.isCompleted) cancelled.complete(); },
    );
    final adapter = _Adapter((_) async => ResponseBody(body.stream, 206));
    adapter.onClose = () {
      body.addError(const SocketException('controlled transport closed'));
      unawaited(body.close());
    };
    final dio = Dio()..httpClientAdapter = adapter;
    final token = CancelToken();
    try {
      final response = await dio.get<ResponseBody>('https://fixture.invalid/hanging',
          options: Options(responseType: ResponseType.stream), cancelToken: token);
      final consumed = response.data!.stream.drain<void>().catchError((Object _) {});
      await listening.future.timeout(const Duration(seconds: 2));
      token.cancel('controlled cancellation');
      dio.close(force: true);
      await consumed.timeout(const Duration(seconds: 2));
      await cancelled.future.timeout(const Duration(seconds: 2));
      expect(adapter.cancellations, 1);
      expect(adapter.closes, 1);
    } finally {
      await body.close();
    }
  });

  test('real IO cancellation disconnects after headers with no response body', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final disconnected = Completer<void>();
    final headers = Completer<void>();
    server.listen((socket) {
      sockets.add(socket);
      var replied = false;
      final request = <int>[];
      void closed() { if (!disconnected.isCompleted) disconnected.complete(); }
      socket.listen((data) {
        request.addAll(data);
        if (!replied && String.fromCharCodes(request).contains('\r\n\r\n')) {
          replied = true;
          socket.write('HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\n'
              'Content-Length: 102400\r\nConnection: close\r\n\r\n');
          // Intentionally never send the declared body.
        }
      }, onDone: closed, onError: (Object _) => closed());
    });
    final dio = buildReleasedIsolatedDio(timeout: const Duration(seconds: 3));
    dio.interceptors.add(InterceptorsWrapper(onResponse: (response, handler) {
      if (!headers.isCompleted) headers.complete();
      handler.next(response);
    }));
    final probe = XbUpdateSourceProbe(dio: dio);
    final url = 'http://127.0.0.1:${server.port}/hanging';
    try {
      final pending = probe.run([url]);
      await headers.future.timeout(const Duration(seconds: 2));
      probe.cancel();
      expect(await pending, [url]);
      await disconnected.future.timeout(const Duration(seconds: 2));
    } finally {
      probe.cancel();
      for (final socket in sockets) { socket.destroy(); }
      await server.close();
    }
  });

  test('real HTTP redirect preserves GET range and ignored Range stops a large stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final methods = <String>[];
    final ranges = <String?>[];
    var written = 0;
    final stopped = Completer<void>();
    server.listen((request) async {
      methods.add(request.method);
      ranges.add(request.headers.value('range'));
      if (request.uri.path == '/bad') {
        request.response.statusCode = 404;
        await request.response.close();
      } else if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/large');
        await request.response.close();
      } else {
        request.response.statusCode = 200; // Deliberately ignore Range.
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = 1024 * 1024;
        try {
          for (var i = 0; i < 512; i++) {
            request.response.add(Uint8List(2048)..[0] = 0x4d);
            written += 2048;
            // After the client cancels a partial response, server-side flush
            // need not complete. Bound the fixture's producer independently.
            await request.response.flush().timeout(const Duration(seconds: 1));
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          await request.response.close().timeout(const Duration(seconds: 1));
        } catch (_) {
          // Client deliberately closes the sampled response before EOF.
        } finally {
          if (!stopped.isCompleted) stopped.complete();
        }
      }
    });
    final base = 'http://127.0.0.1:${server.port}';
    final probe = XbUpdateSourceProbe();
    try {
      expect(await probe.run(['$base/bad','$base/redirect']), ['$base/redirect','$base/bad']);
      await stopped.future.timeout(const Duration(seconds: 3));
      expect(methods, everyElement('GET'));
      expect(ranges, everyElement('bytes=0-102399'));
      expect(methods.length, 3);
      expect(written, lessThan(1024 * 1024));
    } finally {
      probe.cancel();
      await server.close(force: true);
    }
  });
}
