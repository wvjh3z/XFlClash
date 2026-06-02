/// R4.8 — BootstrapManualImport：手动导入应急 config 密文 → 解密校验 → 写缓存。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fl_clash/xboard/config/bootstrap_constants.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/bootstrap_local_loader.dart';
import 'package:fl_clash/xboard/services/bootstrap_manual_import.dart';

import '_bootstrap_crypto_helper.dart';

void main() {
  late BootstrapDecryptor decryptor;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    decryptor = BootstrapDecryptor(aesKey: testAesKey);
  });

  BootstrapManualImport service() => BootstrapManualImport(
        decryptor: decryptor,
        loader: BootstrapLocalLoader(decryptor: decryptor, prefs: prefs),
      );

  /// 合法 config 密文文本（完整 envelope JSON，含 next_bootstrap_urls）。
  Future<String> validConfigText({
    List<String> api = const ['https://api.com'],
    List<String> sub = const ['https://sub.com'],
    List<String> next = const ['https://next.com/config.json'],
  }) async {
    final enc = await encryptPayload({
      'schema_version': 2,
      'api_endpoints': api.map((u) => {'url': u, 'region': 'overseas'}).toList(),
      'subscription_endpoints':
          sub.map((u) => {'url': u, 'region': 'cn'}).toList(),
      'next_bootstrap_urls': next,
    });
    return jsonEncode({'schema_version': 2, 'encrypted': enc});
  }

  test('合法密文 → 成功 + 写缓存 + 写 next_bootstrap_urls', () async {
    final text = await validConfigText(
      api: ['https://api1.com', 'https://api2.com'],
      sub: ['https://sub1.com'],
      next: ['https://next-a.com/config.json'],
    );
    final r = await service().importFromText(text);
    expect(r.ok, isTrue);
    expect(r.apiCount, 2);
    expect(r.subCount, 1);
    // 缓存写入：下次冷启动 loadLocal 能命中。
    expect(prefs.getString(kBootstrapCacheKey), isNotNull);
    // next_bootstrap_urls 滚动写入（R4.7 联动）。
    final loader = BootstrapLocalLoader(decryptor: decryptor, prefs: prefs);
    expect(await loader.readNextBootstrapUrls(),
        ['https://next-a.com/config.json']);
  });

  test('导入后 loadLocal 能从缓存恢复 endpoint', () async {
    final text = await validConfigText(api: ['https://recovered.com']);
    await service().importFromText(text);
    final r = await BootstrapLocalLoader(decryptor: decryptor, prefs: prefs)
        .loadLocal();
    expect(r.source, BootstrapLocalSource.cache);
    expect(r.payload!.apiUrls, ['https://recovered.com']);
  });

  test('空输入 → empty', () async {
    final r = await service().importFromText('   ');
    expect(r.ok, isFalse);
    expect(r.failure, ManualImportFailure.empty);
  });

  test('非 JSON → malformedInput', () async {
    final r = await service().importFromText('这不是 JSON');
    expect(r.failure, ManualImportFailure.malformedInput);
  });

  test('JSON 但缺 encrypted 字段 → malformedInput', () async {
    final r = await service().importFromText('{"schema_version":2}');
    expect(r.failure, ManualImportFailure.malformedInput);
  });

  test('密钥不匹配 → decryptFailed', () async {
    // 用不同 key 加密的密文，当前 decryptor（testAesKey）无法解。
    final wrongKey = List<int>.generate(32, (i) => (i * 3 + 1) % 256);
    final enc = await encryptPayload({
      'schema_version': 2,
      'api_endpoints': [
        {'url': 'https://a.com', 'region': 'cn'}
      ],
      'subscription_endpoints': [
        {'url': 'https://s.com', 'region': 'cn'}
      ],
    }, key: wrongKey);
    final text = jsonEncode({'schema_version': 2, 'encrypted': enc});
    final r = await service().importFromText(text);
    expect(r.failure, ManualImportFailure.decryptFailed);
    // 失败不写缓存。
    expect(prefs.getString(kBootstrapCacheKey), isNull);
  });

  test('解密成功但 endpoint 为空 → decryptFailed（payloadEmpty）', () async {
    final enc = await encryptPayload({
      'schema_version': 2,
      'api_endpoints': <dynamic>[],
      'subscription_endpoints': <dynamic>[],
    });
    final text = jsonEncode({'schema_version': 2, 'encrypted': enc});
    final r = await service().importFromText(text);
    expect(r.failure, ManualImportFailure.decryptFailed);
  });
}
