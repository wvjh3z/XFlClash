/// R4.1 — EncryptedSubscriptionService：URL 方案 b 构造 / 拉取 + 解密 / 错误码分流。
///
/// 复用 bootstrap 加密 helper（[encryptPayloadRaw]）生成合法密文（AAD `xboard-encrypted-sub-v1`），
/// 用 stub adapter 喂给放行 dio，验证解出明文 YAML 字节 + 错误分流。
library;

import 'dart:async';
import 'dart:convert';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/encrypted_subscription_service.dart';
import 'package:fl_clash/xboard/services/xboard_release_dio.dart';

import '_bootstrap_crypto_helper.dart';

/// 可编程 adapter：按 RequestOptions 返回 canned ResponseBody。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
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

  test('慢首地址不阻塞备用地址，赢家取消其他请求', () async {
    final cipher = await encryptPayloadRaw(
      _sampleYaml,
      aad: kEncryptedSubscriptionAad,
    );
    final pending = Completer<ResponseBody>();
    RequestOptions? slow;
    final svc = serviceWith((opts) async {
      if (opts.uri.host == 'slow.test') {
        slow = opts;
        return pending.future;
      }
      return ResponseBody.fromString(cipher, 200);
    });
    final result = await svc.fetchWithFailOver(
      'https://origin.test/sub/token',
      candidateHosts: ['https://slow.test', 'https://good.test'],
    );
    expect(result.winnerUrl, contains('good.test'));
    expect(slow!.cancelToken!.isCancelled, isTrue);
    pending.complete(ResponseBody.fromString(cipher, 200));
  });

  test('慢请求达到单地址时限后释放并发槽，后续候选可成功', () async {
    final cipher = await encryptPayloadRaw(
      _sampleYaml,
      aad: kEncryptedSubscriptionAad,
    );
    final pending = Completer<ResponseBody>();
    final hits = <String>[];
    final svc = serviceWith((o) async {
      hits.add(o.uri.host);
      if (o.uri.host == 'good.test') {
        return ResponseBody.fromString(cipher, 200);
      }
      return pending.future;
    });
    final result = await svc.fetchWithFailOver(
      'https://origin.test/s/token',
      candidateHosts: [
        'https://slow1.test',
        'https://slow2.test',
        'https://good.test',
      ],
      attemptTimeout: const Duration(milliseconds: 30),
      budget: const Duration(seconds: 2),
    );
    expect(result.isSuccess, isTrue);
    expect(hits, ['slow1.test', 'slow2.test', 'good.test']);
    pending.complete(ResponseBody.fromString('invalid', 200));
  });

  test('单个业务拒绝或 HTML 403 不抢先压过有效订阅', () async {
    final cipher = await encryptPayloadRaw(
      _sampleYaml,
      aad: kEncryptedSubscriptionAad,
    );
    for (final body in ['{"code":40305}', '<html>Forbidden</html>']) {
      final svc = serviceWith((opts) async {
        if (opts.uri.host == 'bad.test') {
          return ResponseBody.fromString(body, 403);
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return ResponseBody.fromString(cipher, 200);
      });
      expect(
        (await svc.fetchWithFailOver(
          'https://origin.test/s/token',
          candidateHosts: ['https://bad.test', 'https://good.test'],
        )).isSuccess,
        isTrue,
      );
    }
  });

  test('VPN 开启：海外挂起仍给中国地址预留预算，组内不超过两个请求', () async {
    final cipher = await encryptPayloadRaw(
      _sampleYaml,
      aad: kEncryptedSubscriptionAad,
    );
    final hits = <String>[];
    final pending = Completer<ResponseBody>();
    final svc = serviceWith((opts) async {
      hits.add(opts.uri.host);
      if (opts.uri.host == 'cn.test') {
        return ResponseBody.fromString(cipher, 200);
      }
      return pending.future;
    });
    final result = await svc.fetchWithFailOver(
      'https://origin.test/s/token',
      candidateHosts: [],
      endpoints: [
        const BootstrapEndpoint(
          url: 'https://cn.test',
          region: BootstrapRegion.cn,
        ),
        for (var i = 0; i < 7; i++)
          BootstrapEndpoint(
            url: 'https://o$i.test',
            region: BootstrapRegion.overseas,
          ),
      ],
      vpnActive: true,
      budget: const Duration(milliseconds: 400),
      attemptTimeout: const Duration(seconds: 1),
    );
    expect(result.winnerUrl, contains('cn.test'));
    expect(hits, ['o0.test', 'o1.test', 'cn.test']);
    pending.complete(ResponseBody.fromString(cipher, 200));
  });

  test('VPN 开启且海外成功，不请求更靠前的中国地址', () async {
    final cipher = await encryptPayloadRaw(
      _sampleYaml,
      aad: kEncryptedSubscriptionAad,
    );
    final hits = <String>[];
    final svc = serviceWith((opts) async {
      hits.add(opts.uri.host);
      return ResponseBody.fromString(cipher, 200);
    });
    final result = await svc.fetchWithFailOver(
      'https://origin.test/s/token',
      candidateHosts: [],
      endpoints: const [
        BootstrapEndpoint(url: 'https://cn.test', region: BootstrapRegion.cn),
        BootstrapEndpoint(
          url: 'https://overseas.test',
          region: BootstrapRegion.overseas,
        ),
      ],
      vpnActive: true,
    );
    expect(result.isSuccess, isTrue);
    expect(hits, ['overseas.test']);
  });

  test('候选为空也受硬截止控制，外部取消结束整个竞速', () async {
    final pending = Completer<ResponseBody>();
    final svc = serviceWith((_) => pending.future);
    expect(
      (await svc.fetchWithFailOver(
        'https://origin.test/s/token',
        candidateHosts: [],
        budget: const Duration(milliseconds: 30),
      )).failure,
      EncryptedSubscriptionFailure.network,
    );
    final cancel = CancelToken();
    final future = svc.fetchWithFailOver(
      'https://origin.test/s/token',
      candidateHosts: [],
      cancelToken: cancel,
    );
    cancel.cancel();
    expect((await future).isSuccess, isFalse);
    pending.complete(ResponseBody.fromString('invalid', 200));
  });

  test('可解密但不是配置的内容不能成为赢家', () async {
    final bad = await encryptPayloadRaw(
      '<html>error</html>',
      aad: kEncryptedSubscriptionAad,
    );
    final good = await encryptPayloadRaw(
      _sampleYaml,
      aad: kEncryptedSubscriptionAad,
    );
    final svc = serviceWith(
      (o) async =>
          ResponseBody.fromString(o.uri.host == 'bad.test' ? bad : good, 200),
    );
    final result = await svc.fetchWithFailOver(
      'https://origin.test/s/token',
      candidateHosts: ['https://bad.test', 'https://good.test'],
    );
    expect(result.winnerUrl, contains('good.test'));
  });

  group('buildEncryptedUrl（方案 b：/{token} 前插 /encrypted/）', () {
    test('标准订阅 URL → 插入 encrypted 段', () {
      final r = EncryptedSubscriptionService.buildEncryptedUrl(
        'https://h.com/thunder/b012ef',
      );
      expect(r, 'https://h.com/thunder/encrypted/b012ef');
    });

    test('保留 query', () {
      final r = EncryptedSubscriptionService.buildEncryptedUrl(
        'https://h.com/s/tok?flag=clash',
      );
      expect(r, 'https://h.com/s/encrypted/tok?flag=clash');
    });

    test('单段路径（path 即 token）→ /encrypted/token', () {
      final r = EncryptedSubscriptionService.buildEncryptedUrl(
        'https://h.com/tok123',
      );
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
      final cipher = await encryptPayloadRaw(
        _sampleYaml,
        aad: kEncryptedSubscriptionAad,
      );
      final svc = serviceWith(
        (opts) async => ResponseBody.fromString(
          jsonEncode({'schema_version': 1, 'encrypted': cipher}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final r = await svc.fetch('https://h.com/thunder/b012ef');
      expect(r.isSuccess, isTrue);
      expect(utf8.decode(r.yamlBytes!), _sampleYaml);
      expect(r.winnerUrl, 'https://h.com/thunder/encrypted/b012ef');
    });

    test('裸 base64 密文（text/plain，后端默认形态）→ 解出明文', () async {
      final cipher = await encryptPayloadRaw(
        _sampleYaml,
        aad: kEncryptedSubscriptionAad,
      );
      final svc = serviceWith(
        (opts) async => ResponseBody.fromString(
          cipher,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      );
      final r = await svc.fetch('https://h.com/thunder/b012ef');
      expect(r.isSuccess, isTrue);
      expect(utf8.decode(r.yamlBytes!), _sampleYaml);
    });

    test('命中 URL 走方案 b 改写（adapter 收到 encrypted 段）', () async {
      final cipher = await encryptPayloadRaw(
        _sampleYaml,
        aad: kEncryptedSubscriptionAad,
      );
      final adapter = _StubAdapter(
        (opts) async => ResponseBody.fromString(
          cipher,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      );
      final svc = serviceWith(
        (_) async => throw StateError('unused'),
        adapter: adapter,
      );
      await svc.fetch('https://h.com/thunder/b012ef');
      expect(
        adapter.lastRequest!.uri.toString(),
        'https://h.com/thunder/encrypted/b012ef',
      );
    });

    test('R4.4：订阅拉取 UA 是浏览器 UA（无 flclash 特征）', () async {
      final cipher = await encryptPayloadRaw(
        _sampleYaml,
        aad: kEncryptedSubscriptionAad,
      );
      final adapter = _StubAdapter(
        (opts) async => ResponseBody.fromString(
          cipher,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      );
      // 用放行 dio 工厂（带 UA 默认 header），不注入裸 Dio。
      final svc = EncryptedSubscriptionService(
        decryptor: decryptor,
        dio: buildReleasedIsolatedDio(timeout: const Duration(seconds: 5))
          ..httpClientAdapter = adapter,
      );
      await svc.fetch('https://h.com/thunder/b012ef');
      final ua = adapter.lastRequest!.headers['User-Agent']?.toString() ?? '';
      expect(ua.toLowerCase().contains('flclash'), isFalse);
      expect(ua.startsWith('Mozilla/5.0'), isTrue);
    });
  });

  group('fetch — 错误分流', () {
    test('getSubscribeUrl 非法（无路径段）→ noSubscribeUrl', () async {
      final svc = serviceWith((opts) async => ResponseBody.fromString('', 200));
      final r = await svc.fetch('https://h.com');
      expect(r.failure, EncryptedSubscriptionFailure.noSubscribeUrl);
    });

    test('40302 invalid token → unauthorized + 透传 message', () async {
      final svc = serviceWith(
        (opts) async => ResponseBody.fromString(
          jsonEncode({'code': 40302, 'message': 'invalid token'}),
          403,
        ),
      );
      final r = await svc.fetch('https://h.com/thunder/badtok');
      expect(r.failure, EncryptedSubscriptionFailure.unauthorized);
      expect(r.serverMessage, 'invalid token');
    });

    test('40305 no active plan → noActivePlan', () async {
      final svc = serviceWith(
        (opts) async => ResponseBody.fromString(
          jsonEncode({'code': 40305, 'message': '无有效套餐'}),
          403,
        ),
      );
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.noActivePlan);
      expect(r.serverMessage, '无有效套餐');
    });

    test(
      '40304 subscription expired → subscriptionExpired（独立码，非 unauthorized）',
      () async {
        final svc = serviceWith(
          (opts) async => ResponseBody.fromString(
            jsonEncode({'code': 40304, 'message': 'subscription expired'}),
            403,
          ),
        );
        final r = await svc.fetch('https://h.com/thunder/tok');
        expect(r.failure, EncryptedSubscriptionFailure.subscriptionExpired);
        expect(r.serverMessage, 'subscription expired');
      },
    );

    test('40307 traffic exhausted → trafficExhausted（v1.1.0）', () async {
      final svc = serviceWith(
        (opts) async => ResponseBody.fromString(
          jsonEncode({'code': 40307, 'message': 'traffic exhausted'}),
          403,
        ),
      );
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.trafficExhausted);
      expect(r.serverMessage, 'traffic exhausted');
    });

    test('50001 encryption not configured → serverNotConfigured', () async {
      final svc = serviceWith(
        (opts) async => ResponseBody.fromString(
          jsonEncode({'code': 50001, 'message': 'not configured'}),
          500,
        ),
      );
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.serverNotConfigured);
    });

    test('裸 404 无法证明插件禁用 → 可尝试其他地址', () async {
      final svc = serviceWith(
        (opts) async => ResponseBody.fromString('Not Found', 404),
      );
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.network);
    });

    test('网络异常 → network', () async {
      final svc = serviceWith(
        (opts) async => throw DioException(requestOptions: opts),
      );
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.network);
    });

    test('200 但密文用错 key 加密 → decryptFailed', () async {
      // 用不同 key 加密 → tag 校验失败。
      final wrongKey = List<int>.generate(32, (i) => 255 - i);
      final cipher = await encryptPayloadRaw(
        _sampleYaml,
        key: wrongKey,
        aad: kEncryptedSubscriptionAad,
      );
      final svc = serviceWith(
        (opts) async => ResponseBody.fromString(
          cipher,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      );
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.decryptFailed);
    });

    test('200 但响应非 envelope（乱码）→ decryptFailed', () async {
      final svc = serviceWith(
        (opts) async =>
            ResponseBody.fromString('!@#%^&*() not base64 not json', 200),
      );
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.decryptFailed);
    });

    test('200 空响应体 → decryptFailed', () async {
      final svc = serviceWith(
        (opts) async => ResponseBody.fromBytes(Uint8List(0), 200),
      );
      final r = await svc.fetch('https://h.com/thunder/tok');
      expect(r.failure, EncryptedSubscriptionFailure.decryptFailed);
    });
  });

  group('fetchWithFailOver — 分组限并发', () {
    Future<ResponseBody> okBody(String cipher) async => ResponseBody.fromString(
      cipher,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );

    test('首发挂（网络错）→ 顺位试第二个成功', () async {
      final cipher = await encryptPayloadRaw(
        _sampleYaml,
        aad: kEncryptedSubscriptionAad,
      );
      final hits = <String>[];
      final adapter = _StubAdapter((opts) async {
        hits.add(opts.uri.host);
        if (opts.uri.host == '1.1.1.1') {
          throw DioException(requestOptions: opts); // 首发网络挂
        }
        return okBody(cipher);
      });
      final svc = serviceWith(
        (_) async => throw StateError('unused'),
        adapter: adapter,
      );
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

    test('所有地址均明确无套餐 → 返回业务结果', () async {
      final hits = <String>[];
      final adapter = _StubAdapter((opts) async {
        hits.add(opts.uri.host);
        return ResponseBody.fromString(
          jsonEncode({'code': 40305, 'message': '无有效套餐'}),
          403,
        );
      });
      final svc = serviceWith(
        (_) async => throw StateError('unused'),
        adapter: adapter,
      );
      final r = await svc.fetchWithFailOver(
        'https://orig.com/thunder/tok',
        candidateHosts: ['https://1.1.1.1', 'https://2.2.2.2'],
      );
      expect(r.failure, EncryptedSubscriptionFailure.noActivePlan);
      expect(r.serverMessage, '无有效套餐');
      // 单个地址的错误不阻止其他候选。
      expect(hits, ['1.1.1.1', '2.2.2.2']);
    });

    test('全部 host 网络挂 → 返最后一次网络失败', () async {
      final hits = <String>[];
      final adapter = _StubAdapter((opts) async {
        hits.add(opts.uri.host);
        throw DioException(requestOptions: opts);
      });
      final svc = serviceWith(
        (_) async => throw StateError('unused'),
        adapter: adapter,
      );
      final r = await svc.fetchWithFailOver(
        'https://orig.com/thunder/tok',
        candidateHosts: [
          'https://1.1.1.1',
          'https://2.2.2.2',
          'https://3.3.3.3',
        ],
      );
      expect(r.failure, EncryptedSubscriptionFailure.network);
      expect(hits, ['1.1.1.1', '2.2.2.2', '3.3.3.3']); // 穷举全部
    });

    test('候选为空 → 退回原始 URL host 兜底拉一次', () async {
      final cipher = await encryptPayloadRaw(
        _sampleYaml,
        aad: kEncryptedSubscriptionAad,
      );
      final hits = <String>[];
      final adapter = _StubAdapter((opts) async {
        hits.add(opts.uri.host);
        return okBody(cipher);
      });
      final svc = serviceWith(
        (_) async => throw StateError('unused'),
        adapter: adapter,
      );
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
      final goodCipher = await encryptPayloadRaw(
        _sampleYaml,
        aad: kEncryptedSubscriptionAad,
      );
      final adapter = _StubAdapter((opts) async {
        if (opts.uri.host == '1.1.1.1') {
          return ResponseBody.fromString('garbage not envelope', 200);
        }
        return okBody(goodCipher);
      });
      final svc = serviceWith(
        (_) async => throw StateError('unused'),
        adapter: adapter,
      );
      final r = await svc.fetchWithFailOver(
        'https://orig.com/thunder/tok',
        candidateHosts: ['https://1.1.1.1', 'https://2.2.2.2'],
      );
      expect(r.isSuccess, isTrue);
    });
  });
}
