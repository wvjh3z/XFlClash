/// R4.1 — EncryptedSubscriptionService：URL 方案 b 构造 / 拉取 + 解密 / 错误码分流。
///
/// 复用 bootstrap 加密 helper（[encryptPayloadRaw]）生成合法密文（AAD `xboard-encrypted-sub-v1`），
/// 用 stub adapter 喂给放行 dio，验证解出明文 YAML 字节 + 错误分流。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/encrypted_subscription_service.dart';

import '_bootstrap_crypto_helper.dart';

/// 可编程 adapter：按 RequestOptions 返回 canned ResponseBody。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) {
    lastRequest = options;
    return handler(options);
  }
}

const String _sampleYaml = '''
proxies:
  - {name: "节点1", type: ss, server: 1.2.3.4, port: 8388}
proxy-groups:
  - {name: "PROXY", type: select, proxies: ["节点1"]}
rules:
  - MATCH,PROXY
''';

void main() {
  late BootstrapDecryptor decryptor;
  setUp(() => decryptor = BootstrapDecryptor(aesKey: testAesKey));

  EncryptedSubscriptionService serviceWith(
    Future<ResponseBody> Function(RequestOptions) handler, {
    _StubAdapter? adapter,
  }) {
    final dio = Dio()..httpClientAdapter = adapter ?? _StubAdapter(handler);
    return EncryptedSubscriptionService(decryptor: decryptor, dio: dio);
  }

  group('buildEncryptedUrl（方案 b：/{token} 前插 /encrypted/）', () {
    test('标准订阅 URL → 插入 encrypted 段', () {
      final r = EncryptedSubscriptionService.buildEncryptedUrl(
          'https://h.com/thunder/b012ef');
      expect(r, 'https://h.com/thunder/encrypted/b012ef');
    });

    test('保留 query', () {
      final r = EncryptedSubscriptionService.buildEncryptedUrl(
          'https://h.com/s/tok?flag=clash');
      expect(r, 'https://h.com/s/encrypted/tok?flag=clash');
    });

    test('单段路径（path 即 token）→ /encrypted/token', () {
      final r = EncryptedSubscriptionService.buildEncryptedUrl(
          'https://h.com/tok123');
      expect(r, 'https://h.com/encrypted/tok123');
    });

    test('overrideHost 替换 scheme+host，保留 path+token', () {
      final r = EncryptedSubscriptionService.buildEncryptedUrl(
        'https://orig.com/thunder/b012ef',
        overrideHost: 'https://5.6.7.8',
      );
      expect(r, 'https://5.6.7.8/thunder/encrypted/b012ef');
    });

    test('overrideHost 带端口', () {
      final r = EncryptedSubscriptionService.buildEncryptedUrl(
        'https://orig.com/thunder/tok',
        overrideHost: 'https://1.2.3.4:8443',
      );
      expect(r, 'https://1.2.3.4:8443/thunder/encrypted/tok');
    });

    test('无路径段 → null', () {
      expect(
        EncryptedSubscriptionService.buildEncryptedUrl('https://h.com'),
        isNull,
      );
    });

    test('非法 URL → null', () {
      expect(
        EncryptedSubscriptionService.buildEncryptedUrl('not a url ::: '),
        isNull,
      );
    });
  });

  group('fetch — 成功路径', () {
    test('JSON 信封密文 → 解出明文 YAML 字节', () async {
      final cipher =
          await encryptPayloadRaw(_sampleYaml, aad: kEncryptedSubscriptionAad);
      final svc = serviceWith((opts) async => ResponseBody.fromString(
            jsonEncode({'schema_version': 1, 'encrypted': cipher}),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType]
            },
          ));
      final r = await svc.fetch('https://h.com/thunder/b012ef');
      expect(r.isSuccess, isTrue);
      expect(utf8.decode(r.yamlBytes!), _sampleYaml);
      expect(r.winnerUrl, 'https://h.com/thunder/encrypted/b012ef');
    });

    test('裸 base64 密文（text/plain，后端默认形态）→ 解出明文', () async {
      final cipher =
          await encryptPayloadRaw(_sampleYaml, aad: kEncryptedSubscriptionAad);
      final svc = serviceWith((opts) async => ResponseBody.fromString(
            cipher,
            200,
            headers: {
              Headers.contentTypeHeader: ['text/plain']
            },
          ));
      final r = await svc.fetch('https://h.com/thunder/b012ef');
      expect(r.isSuccess, isTrue);
      expect(utf8.decode(r.yamlBytes!), _sampleYaml);
    });

    test('命中 URL 走方案 b 改写（adapter 收到 encrypted 段）', () async {
      final cipher =
          await encryptPayloadRaw(_sampleYaml, aad: kEncryptedSubscriptionAad);
      final adapter = _StubAdapter((opts) async => ResponseBody.fromString(
            cipher,
            200,
            headers: {
              Headers.contentTypeHeader: ['text/plain']
            },
          ));
      final svc = serviceWith((_) async => throw StateError('unused'),
          adapter: adapter);
      await svc.fetch('https://h.com/thunder/b012ef');
      expect(adapter.lastRequest!.uri.toString(),
          'https://h.com/thunder/encrypted/b012ef');
    });
  });

  group('fetch — 错误分流', () {
    test('getSubscribeUrl 非法（无路径段）→ noSubscribeUrl', () async {
      final svc = serviceWith((opts) async => ResponseBody.fromString('', 200));
      final r = await svc.fetch('https://h.com');
      expect(r.failure, EncryptedSubscriptionFailure.noSubscribeUrl);
    });

    test('40302 invalid token → unauthorized + 透传 message', () async {
      final svc = serviceWith((opts) async => ResponseBody.fromString(
            jsonEncode({'code': 40302, 'message': 'invalid token'}),
            403,
          ));
      final r = await svc.fetch('https://h.com/thunder/badtok');
      expect(r.failure, EncryptedSubscriptionFailure.unauthorized);
      expect(r.serverMessage, 'invalid token');
    });

    test('40305 no active plan → noActivePlan', () async {
      final svc = serviceWith((opts) async => ResponseBody.fromString(
            jsonEncode({'code': 40305, 'message': '无有效套餐'}),
            403,
          ));
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.noActivePlan);
      expect(r.serverMessage, '无有效套餐');
    });

    test('50001 encryption not configured → serverNotConfigured', () async {
      final svc = serviceWith((opts) async => ResponseBody.fromString(
            jsonEncode({'code': 50001, 'message': 'not configured'}),
            500,
          ));
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.serverNotConfigured);
    });

    test('404 插件禁用 → serverNotConfigured', () async {
      final svc = serviceWith(
          (opts) async => ResponseBody.fromString('Not Found', 404));
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.serverNotConfigured);
    });

    test('网络异常 → network', () async {
      final svc = serviceWith(
          (opts) async => throw DioException(requestOptions: opts));
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.network);
    });

    test('200 但密文用错 key 加密 → decryptFailed', () async {
      // 用不同 key 加密 → tag 校验失败。
      final wrongKey = List<int>.generate(32, (i) => 255 - i);
      final cipher = await encryptPayloadRaw(_sampleYaml,
          key: wrongKey, aad: kEncryptedSubscriptionAad);
      final svc = serviceWith((opts) async => ResponseBody.fromString(
            cipher,
            200,
            headers: {
              Headers.contentTypeHeader: ['text/plain']
            },
          ));
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.decryptFailed);
    });

    test('200 但响应非 envelope（乱码）→ decryptFailed', () async {
      final svc = serviceWith((opts) async => ResponseBody.fromString(
            '!@#%^&*() not base64 not json',
            200,
          ));
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.decryptFailed);
    });

    test('200 空响应体 → decryptFailed', () async {
      final svc = serviceWith(
          (opts) async => ResponseBody.fromBytes(Uint8List(0), 200));
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.decryptFailed);
    });
  });

  group('fetchWithFailOver — R4.2 串行 failOver', () {
    Future<ResponseBody> okBody(String cipher) async => ResponseBody.fromString(
          cipher,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain']
          },
        );

    test('首发挂（网络错）→ 顺位试第二个成功', () async {
      final cipher =
          await encryptPayloadRaw(_sampleYaml, aad: kEncryptedSubscriptionAad);
      final hits = <String>[];
      final adapter = _StubAdapter((opts) async {
        hits.add(opts.uri.host);
        if (opts.uri.host == '1.1.1.1') {
          throw DioException(requestOptions: opts); // 首发网络挂
        }
        return okBody(cipher);
      });
      final svc = serviceWith((_) async => throw StateError('unused'),
          adapter: adapter);
      final r = await svc.fetchWithFailOver(
        'https://orig.com/thunder/tok',
        candidateHosts: ['https://1.1.1.1', 'https://2.2.2.2'],
      );
      expect(r.isSuccess, isTrue);
      expect(utf8.decode(r.yamlBytes!), _sampleYaml);
      // 试了首发（挂）再到第二个（成功），URL 走方案 b 改写。
      expect(hits, ['1.1.1.1', '2.2.2.2']);
      expect(r.winnerUrl, 'https://2.2.2.2/thunder/encrypted/tok');
    });

    test('业务错误（无套餐）→ 立即停，不试后续 host', () async {
      final hits = <String>[];
      final adapter = _StubAdapter((opts) async {
        hits.add(opts.uri.host);
        return ResponseBody.fromString(
          jsonEncode({'code': 40305, 'message': '无有效套餐'}),
          403,
        );
      });
      final svc = serviceWith((_) async => throw StateError('unused'),
          adapter: adapter);
      final r = await svc.fetchWithFailOver(
        'https://orig.com/thunder/tok',
        candidateHosts: ['https://1.1.1.1', 'https://2.2.2.2'],
      );
      expect(r.failure, EncryptedSubscriptionFailure.noActivePlan);
      expect(r.serverMessage, '无有效套餐');
      // 换 host 无意义 → 只试了首发就停。
      expect(hits, ['1.1.1.1']);
    });

    test('全部 host 网络挂 → 返最后一次网络失败', () async {
      final hits = <String>[];
      final adapter = _StubAdapter((opts) async {
        hits.add(opts.uri.host);
        throw DioException(requestOptions: opts);
      });
      final svc = serviceWith((_) async => throw StateError('unused'),
          adapter: adapter);
      final r = await svc.fetchWithFailOver(
        'https://orig.com/thunder/tok',
        candidateHosts: ['https://1.1.1.1', 'https://2.2.2.2', 'https://3.3.3.3'],
      );
      expect(r.failure, EncryptedSubscriptionFailure.network);
      expect(hits, ['1.1.1.1', '2.2.2.2', '3.3.3.3']); // 穷举全部
    });

    test('候选为空 → 退回原始 URL host 兜底拉一次', () async {
      final cipher =
          await encryptPayloadRaw(_sampleYaml, aad: kEncryptedSubscriptionAad);
      final hits = <String>[];
      final adapter = _StubAdapter((opts) async {
        hits.add(opts.uri.host);
        return okBody(cipher);
      });
      final svc = serviceWith((_) async => throw StateError('unused'),
          adapter: adapter);
      final r = await svc.fetchWithFailOver(
        'https://orig.com/thunder/tok',
        candidateHosts: const [],
      );
      expect(r.isSuccess, isTrue);
      // 用原始 host（未替换），仍走方案 b 插 encrypted。
      expect(hits, ['orig.com']);
      expect(r.winnerUrl, 'https://orig.com/thunder/encrypted/tok');
    });

    test('解密失败（坏数据）也算可换 host → 试下一个', () async {
      final goodCipher =
          await encryptPayloadRaw(_sampleYaml, aad: kEncryptedSubscriptionAad);
      final adapter = _StubAdapter((opts) async {
        if (opts.uri.host == '1.1.1.1') {
          return ResponseBody.fromString('garbage not envelope', 200);
        }
        return okBody(goodCipher);
      });
      final svc = serviceWith((_) async => throw StateError('unused'),
          adapter: adapter);
      final r = await svc.fetchWithFailOver(
        'https://orig.com/thunder/tok',
        candidateHosts: ['https://1.1.1.1', 'https://2.2.2.2'],
      );
      expect(r.isSuccess, isTrue);
    });
  });
}
