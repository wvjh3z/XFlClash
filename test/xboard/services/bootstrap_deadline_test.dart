import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/bootstrap_fetcher.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/models/bootstrap_envelope.dart';
import '_bootstrap_crypto_helper.dart';
import 'package:fl_clash/xboard/services/xboard_release_dio.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions, Future<void>?) handler;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<List<int>>? data,
    Future<void>? cancel,
  ) => handler(o, cancel);
}

class _DelayedDecryptor extends BootstrapDecryptor {
  _DelayedDecryptor() : super(aesKey: testAesKey);
  final began = Completer<void>();
  final gate = Completer<BootstrapDecryptResult>();
  @override
  Future<BootstrapDecryptResult> decryptAndValidate(BootstrapEnvelope env) {
    began.complete();
    return gate.future;
  }
}

void main() {
  test(
    'total deadline cancels in-flight request and starts no fallback',
    () async {
      final cancelled = Completer<void>();
      var calls = 0;
      final pending = Completer<ResponseBody>();
      final dio = Dio()
        ..httpClientAdapter = _Adapter((o, cancel) {
          calls++;
          cancel!.then((_) {
            if (!cancelled.isCompleted) cancelled.complete();
          });
          return pending.future;
        });
      addTearDown(() => dio.close(force: true));
      final fetcher = BootstrapFetcher(
        decryptor: BootstrapDecryptor(aesKey: testAesKey),
        dio: dio,
      );
      final elapsed = Stopwatch()..start();
      final result = await fetcher.fetchRemote([
        'https://a.test',
        'https://b.test',
      ], budget: const Duration(seconds: 1));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
      expect(result.isSuccess, isFalse);
      await cancelled.future.timeout(const Duration(seconds: 2));
      expect(calls, 1);
      pending.complete(ResponseBody.fromString('{}', 200));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
    },
  );
  test(
    'attempt deadline permits one same-mirror retry then next mirror',
    () async {
      final envelope = await validEnvelope();
      var calls = 0;
      var cancels = 0;
      final delayed = <Completer<ResponseBody>>[];
      final dio = Dio()
        ..httpClientAdapter = _Adapter((o, cancel) async {
          calls++;
          if (o.uri.host == 'a.test') {
            unawaited(
              cancel!.then((_) {
                cancels++;
              }),
            );
            final gate = Completer<ResponseBody>();
            delayed.add(gate);
            return gate.future;
          }
          return ResponseBody.fromString(jsonEncode(envelope.toJson()), 200);
        });
      addTearDown(() => dio.close(force: true));
      final result =
          await BootstrapFetcher(
            decryptor: BootstrapDecryptor(aesKey: testAesKey),
            dio: dio,
          ).fetchRemote(
            ['https://a.test', 'https://b.test'],
            budget: const Duration(seconds: 8),
            attemptTimeout: const Duration(seconds: 1),
          );
      expect(result.isSuccess, isTrue);
      expect(calls, 3);
      expect(cancels, 2);
      for (final gate in delayed) {
        gate.complete(ResponseBody.fromString('{}', 200));
      }
    },
  );
  test(
    'late successful decryption is not published after total deadline',
    () async {
      final env = await validEnvelope();
      final real = await BootstrapDecryptor(
        aesKey: testAesKey,
      ).decryptAndValidate(env);
      final decryptor = _DelayedDecryptor();
      var calls = 0;
      final dio = Dio()
        ..httpClientAdapter = _Adapter((o, cancel) async {
          calls++;
          return ResponseBody.fromString(jsonEncode(env.toJson()), 200);
        });
      addTearDown(() => dio.close(force: true));
      final pending = BootstrapFetcher(decryptor: decryptor, dio: dio)
          .fetchRemote([
            'https://a.test',
            'https://b.test',
          ], budget: const Duration(seconds: 1));
      await decryptor.began.future;
      final result = await pending;
      expect(result.isSuccess, isFalse);
      decryptor.gate.complete(real);
      await Future<void>.delayed(Duration.zero);
      expect(result.winnerEnvelope, isNull);
      expect(calls, 1);
    },
  );
  test('empty/zero budget performs no network requests', () async {
    var calls = 0;
    final dio = Dio()
      ..httpClientAdapter = _Adapter((o, c) async {
        calls++;
        return ResponseBody.fromString('{}', 200);
      });
    addTearDown(() => dio.close(force: true));
    final fetcher = BootstrapFetcher(
      decryptor: BootstrapDecryptor(aesKey: testAesKey),
      dio: dio,
    );
    expect((await fetcher.fetchRemote([])).isSuccess, isFalse);
    expect(
      (await fetcher.fetchRemote([
        'https://a.test',
      ], budget: Duration.zero)).isSuccess,
      isFalse,
    );
    expect(calls, 0);
  });
  test(
    'real HTTP ongoing body is cancelled instead of extending total budget',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final stop = Completer<void>();
      var receivedBytes = 0;
      var calls = 0;
      addTearDown(() async {
        if (!stop.isCompleted) stop.complete();
        await server.close(force: true);
      });
      server.listen((r) async {
        calls++;
        r.response.bufferOutput = false;
        try {
          while (!stop.isCompleted) {
            r.response.write(' ');
            await r.response.flush();
            await Future.any([
              stop.future,
              Future<void>.delayed(const Duration(milliseconds: 100)),
            ]);
          }
        } catch (_) {
          // Server-side writes need not report peer closure immediately.
        } finally {
          try {
            await r.response.close();
          } catch (_) {}
        }
      });
      final dio = buildReleasedIsolatedDio(timeout: const Duration(seconds: 5));
      addTearDown(() => dio.close(force: true));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.onReceiveProgress = (count, total) => receivedBytes = count;
            handler.next(options);
          },
        ),
      );
      final clock = Stopwatch()..start();
      final result =
          await BootstrapFetcher(
            decryptor: BootstrapDecryptor(aesKey: testAesKey),
            dio: dio,
          ).fetchRemote([
            'http://127.0.0.1:${server.port}/config.json',
          ], budget: const Duration(seconds: 1));
      expect(result.isSuccess, isFalse);
      expect(calls, 1);
      expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
      expect(receivedBytes, greaterThan(0));
      final atCancellation = receivedBytes;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(receivedBytes, atCancellation);
    },
  );
}
