/// W5.1.9 — BootstrapFetcher：串行命中首个有效镜像 / 全失败降级 / θ-1（隔离 dio 不继承全局）。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/bootstrap_envelope.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/bootstrap_fetcher.dart';

import '_bootstrap_crypto_helper.dart';

/// 可编程 adapter：按 URL 返回 canned envelope JSON / 状态码 / 抛错。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream,
          Future<void>? cancelFuture) =>
      handler(options);
}

ResponseBody _jsonBody(Map<String, dynamic> json, {int code = 200}) =>
    ResponseBody.fromString(jsonEncode(json), code,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });

void main() {
  late BootstrapDecryptor decryptor;
  setUp(() => decryptor = BootstrapDecryptor(aesKey: testAesKey));

  BootstrapFetcher fetcherWith(
      Future<ResponseBody> Function(RequestOptions) handler) {
    final dio = Dio()..httpClientAdapter = _StubAdapter(handler);
    return BootstrapFetcher(decryptor: decryptor, dio: dio);
  }

  test('首个镜像返合法密文 → success + winnerUrl', () async {
    final env = await validEnvelope(api: ['https://win.com']);
    final fetcher = fetcherWith((opts) async =>
        _jsonBody({'schema_version': 1, 'encrypted': env.encrypted}));
    final r = await fetcher.fetchRemote(['https://m1.com']);
    expect(r.isSuccess, isTrue);
    expect(r.winnerUrl, 'https://m1.com');
    expect(r.payload!.apiEndpoints, ['https://win.com']);
  });

  test('第一个镜像失败 → 串行 fallback 到第二个', () async {
    final env = await validEnvelope();
    final fetcher = fetcherWith((opts) async {
      if (opts.uri.toString().contains('m1')) {
        return _jsonBody({}, code: 500); // m1 5xx
      }
      return _jsonBody({'schema_version': 1, 'encrypted': env.encrypted});
    });
    final r = await fetcher.fetchRemote(['https://m1.com', 'https://m2.com']);
    expect(r.isSuccess, isTrue);
    expect(r.winnerUrl, 'https://m2.com');
  });

  test('全部镜像失败 → payload=null（降级沿用本地）', () async {
    final fetcher =
        fetcherWith((opts) async => throw DioException(requestOptions: opts));
    final r = await fetcher.fetchRemote(['https://m1.com', 'https://m2.com']);
    expect(r.isSuccess, isFalse);
    expect(r.payload, isNull);
  });

  test('镜像返非密文 JSON（解密失败）→ 记录 lastFailure', () async {
    final fetcher = fetcherWith((opts) async => _jsonBody(
        {'schema_version': 1, 'encrypted': 'QUJD'})); // 过短
    final r = await fetcher.fetchRemote(['https://m1.com']);
    expect(r.isSuccess, isFalse);
    expect(r.lastFailure, BootstrapDecryptFailure.malformedCiphertext);
  });
}
