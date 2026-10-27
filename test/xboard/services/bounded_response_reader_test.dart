import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/services/bounded_response_reader.dart';
import 'package:fl_clash/xboard/services/bootstrap_fetcher.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/encrypted_subscription_service.dart';
import 'package:fl_clash/xboard/services/xboard_release_dio.dart';
import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import '_bootstrap_crypto_helper.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<List<int>>? data,
    Future<void>? cancel,
  ) => handler(o);
}

class _Decryptor extends BootstrapDecryptor {
  _Decryptor() : super(aesKey: testAesKey);
  int decrypts = 0;
  @override
  Future<RawDecryptResult> decryptCiphertext({
    required String base64Cipher,
    required String aad,
  }) {
    decrypts++;
    return super.decryptCiphertext(base64Cipher: base64Cipher, aad: aad);
  }
}

void main() {
  for (final size in [0, 1023, 1024, 1025]) {
    for (final mode in ['length', 'chunked', 'gzip']) {
      test('real $mode decoded size=$size limit=1024', () async {
        final data = Uint8List(size)..fillRange(0, size, 32);
        final wire = mode == 'gzip' ? gzip.encode(data) : data;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) async {
          if (mode != 'chunked') {
            r.response.contentLength = wire.length;
          }
          if (mode == 'gzip') {
            r.response.headers.set('Content-Encoding', 'gzip');
          }
          r.response.add(wire);
          await r.response.close();
        });
        final dio = buildReleasedIsolatedDio(
          timeout: const Duration(seconds: 5),
        );
        addTearDown(() => dio.close(force: true));
        final pending = readBoundedResponse(
          dio,
          Uri.parse('http://127.0.0.1:${server.port}'),
          maxBytes: 1024,
        );
        if (size > 1024) {
          await expectLater(pending, throwsA(isA<ResponseTooLargeException>()));
        } else {
          expect((await pending).data, data);
        }
      });
    }
  }
  test(
    'overflow cancels upstream, ignores misleading length, does not cancel sibling token',
    () async {
      final cancelled = Completer<void>();
      final source = StreamController<Uint8List>(
        onCancel: () => cancelled.complete(),
      );
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (o) async => ResponseBody(
            source.stream,
            403,
            headers: {
              'content-length': ['1'],
            },
          ),
        );
      addTearDown(() => dio.close(force: true));
      final parent = CancelToken();
      final sibling = CancelToken();
      final pending = readBoundedResponse(
        dio,
        Uri.parse('https://fixture.test'),
        maxBytes: 4,
        cancelToken: parent,
      );
      final check = expectLater(
        pending,
        throwsA(isA<ResponseTooLargeException>()),
      );
      source.add(Uint8List(3));
      source.add(Uint8List(2));
      await check;
      await cancelled.future.timeout(const Duration(seconds: 3));
      expect(parent.isCancelled, isTrue);
      expect(sibling.isCancelled, isFalse);
      await source.close();
    },
  );
  test('parent cancellation stops an ongoing response', () async {
    final ready = Completer<void>();
    final stopped = Completer<void>();
    final source = StreamController<Uint8List>(
      onCancel: () => stopped.complete(),
    );
    final dio = Dio()
      ..httpClientAdapter = _Adapter((o) async {
        ready.complete();
        return ResponseBody(source.stream, 200);
      });
    addTearDown(() => dio.close(force: true));
    final token = CancelToken();
    final check = expectLater(
      readBoundedResponse(
        dio,
        Uri.parse('https://fixture.test'),
        maxBytes: 4,
        cancelToken: token,
      ),
      throwsA(isA<DioException>()),
    );
    await ready.future;
    source.add(Uint8List(1));
    token.cancel('fixture');
    await check;
    await stopped.future.timeout(const Duration(seconds: 3));
    await source.close();
  });
  test('already cancelled request does not dispatch', () async {
    var count = 0;
    final dio = Dio()
      ..httpClientAdapter = _Adapter((o) async {
        count++;
        return ResponseBody.fromString('ok', 200);
      });
    addTearDown(() => dio.close(force: true));
    final token = CancelToken()..cancel();
    await expectLater(
      readBoundedResponse(
        dio,
        Uri.parse('https://fixture.test'),
        maxBytes: 4,
        cancelToken: token,
      ),
      throwsA(isA<DioException>()),
    );
    expect(count, 0);
  });
  for (final brand in ['brand_a', 'brand_b']) {
    for (final channel in ['bootstrap', 'subscription']) {
      test(
        '$brand $channel overflow skips decrypt and retains healthy mirror',
        () async {
          final encrypted = await encryptPayloadRaw(
            'proxies: []\n',
            aad: kEncryptedSubscriptionAad,
          );
          final good = jsonEncode(
            channel == 'bootstrap'
                ? (await validEnvelope()).toJson()
                : {'schema_version': 1, 'encrypted': encrypted},
          );
          final calls = <String>[];
          final decryptor = _Decryptor();
          final dio = Dio()
            ..httpClientAdapter = _Adapter((o) async {
              calls.add(o.uri.host);
              return o.uri.host == 'large.test'
                  ? ResponseBody.fromBytes(Uint8List(4097), 200)
                  : ResponseBody.fromString(good, 200);
            });
          addTearDown(() => dio.close(force: true));
          if (channel == 'bootstrap') {
            final result = await BootstrapFetcher(
              decryptor: decryptor,
              dio: dio,
              maxResponseBytes: 4096,
            ).fetchRemote(['https://large.test', 'https://good.test']);
            expect(result.isSuccess, isTrue);
            expect(result.winnerUrl, 'https://good.test');
          } else {
            final result =
                await EncryptedSubscriptionService(
                  decryptor: decryptor,
                  dio: dio,
                  maxResponseBytes: 4096,
                ).fetchWithFailOver(
                  'https://original.test/sub/fixture',
                  candidateHosts: ['https://large.test', 'https://good.test'],
                );
            expect(result.isSuccess, isTrue);
            expect(result.winnerUrl, contains('good.test'));
          }
          expect(calls.where((e) => e == 'large.test').length, 1);
          expect(decryptor.decrypts, 1);
        },
      );
    }
  }
  test(
    'bounded HTTP error preserves subscription business classification',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (o) async => ResponseBody.fromString(
            '{"code":40304,"message":"expired"}',
            403,
          ),
        );
      addTearDown(() => dio.close(force: true));
      final result = await EncryptedSubscriptionService(
        decryptor: BootstrapDecryptor(aesKey: testAesKey),
        dio: dio,
      ).fetch('https://fixture.test/sub/token');
      expect(result.failure, EncryptedSubscriptionFailure.subscriptionExpired);
    },
  );
  for (final channel in ['bootstrap', 'subscription']) {
    test(
      '$channel all oversized candidates never decrypt or publish payload',
      () async {
        final decryptor = _Decryptor();
        var calls = 0;
        final dio = Dio()
          ..httpClientAdapter = _Adapter((options) async {
            calls++;
            return ResponseBody.fromBytes(Uint8List(5), 200);
          });
        addTearDown(() => dio.close(force: true));
        if (channel == 'bootstrap') {
          final result = await BootstrapFetcher(
            decryptor: decryptor,
            dio: dio,
            maxResponseBytes: 4,
          ).fetchRemote(['https://a.test', 'https://b.test']);
          expect(result.payload, isNull);
          expect(result.winnerEnvelope, isNull);
        } else {
          final result =
              await EncryptedSubscriptionService(
                decryptor: decryptor,
                dio: dio,
                maxResponseBytes: 4,
              ).fetchWithFailOver(
                'https://original.test/sub/fixture',
                candidateHosts: ['https://a.test', 'https://b.test'],
              );
          expect(result.yamlBytes, isNull);
          expect(result.failure, EncryptedSubscriptionFailure.decryptFailed);
        }
        expect(calls, 2);
        expect(decryptor.decrypts, 0);
      },
    );
  }

  test('successful response does not cancel caller request token', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        (options) async => ResponseBody.fromString('ok', 200),
      );
    addTearDown(() => dio.close(force: true));
    final token = CancelToken();
    final response = await readBoundedResponse(
      dio,
      Uri.parse('https://fixture.test'),
      maxBytes: 2,
      cancelToken: token,
    );
    expect(utf8.decode(response.data!), 'ok');
    expect(token.isCancelled, isFalse);
  });
}
