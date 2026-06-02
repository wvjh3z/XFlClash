/// W5.7 — 远端阶段 Sentry tag 分级 wire（DD-23 / λ-4）。
///
/// 验证：
/// - 5 种解密失败路径 + noKey 各打不同 `decryption_failure` 值（5.7.3）；
/// - 3 种本地来源 `envelope_source` 值映射（5.7.2）；
/// - BootstrapFetcher 全镜像失败 → 真实打 `decryption_failure` tag；
/// - EndpointRaceController.raceApi 递增 `endpoint.race_attempts`；
/// - flavor.id / auth.state / connectivity.online 便捷方法（5.7.2 剩余 3 类）。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/services/bootstrap_decryptor.dart';
import 'package:fl_clash/xboard/services/bootstrap_fetcher.dart';
import 'package:fl_clash/xboard/services/bootstrap_local_loader.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';

void main() {
  setUp(SentryBootstrap.resetForTest);

  group('5.7.3 decryptionFailure tagValue 5 路径各异（+ noKey）', () {
    test('6 枚举值映射两两不同且非空', () {
      final values =
          BootstrapDecryptFailure.values.map((e) => e.tagValue).toList();
      expect(values.toSet().length, values.length); // 全互异
      expect(values.every((v) => v.isNotEmpty), isTrue);
    });
    test('具体值锁定（值域稳定，便于 Sentry 仪表盘聚合）', () {
      expect(BootstrapDecryptFailure.schemaIncompatible.tagValue,
          'schema_incompatible');
      expect(BootstrapDecryptFailure.malformedCiphertext.tagValue,
          'malformed_ciphertext');
      expect(BootstrapDecryptFailure.decryptError.tagValue, 'decrypt_error');
      expect(BootstrapDecryptFailure.payloadParseError.tagValue,
          'payload_parse_error');
      expect(BootstrapDecryptFailure.payloadEmpty.tagValue, 'payload_empty');
      expect(BootstrapDecryptFailure.noKey.tagValue, 'no_key');
    });
  });

  group('5.7.2 envelopeSource tagValue 3 来源', () {
    test('cache/fallback_asset/none', () {
      expect(BootstrapLocalSource.cache.tagValue, 'cache');
      expect(BootstrapLocalSource.fallbackAsset.tagValue, 'fallback_asset');
      expect(BootstrapLocalSource.none.tagValue, 'none');
    });
  });

  group('BootstrapFetcher wire decryption_failure（全镜像失败 → 真实打 tag）', () {
    test('schemaIncompatible 镜像 → decryption_failure=schema_incompatible', () async {
      // 注入 dio：返 schemaVersion=0 的 envelope → 解密器判 schemaIncompatible。
      final dio = Dio()
        ..httpClientAdapter = _MapAdapter((uri) => {
              'schema_version': 0,
              'encrypted': 'QUFBQQ==',
            });
      final fetcher = BootstrapFetcher(
        decryptor: BootstrapDecryptor(aesKey: List<int>.filled(32, 1)),
        dio: dio,
      );
      final r = await fetcher.fetchRemote(['https://m1.example.com']);
      expect(r.isSuccess, isFalse);
      expect(r.lastFailure, BootstrapDecryptFailure.schemaIncompatible);
      expect(SentryBootstrap.tagsSnapshot[SentryTagKeys.decryptionFailure],
          'schema_incompatible');
    });

    test('noKey 镜像（flavor 无 key）→ decryption_failure=no_key', () async {
      final dio = Dio()
        ..httpClientAdapter = _MapAdapter((uri) => {
              'schema_version': 1,
              'encrypted': 'QUFBQQ==',
            });
      final fetcher = BootstrapFetcher(
        decryptor: BootstrapDecryptor(aesKey: null), // 未配置 key
        dio: dio,
      );
      final r = await fetcher.fetchRemote(['https://m1.example.com']);
      expect(r.lastFailure, BootstrapDecryptFailure.noKey);
      expect(SentryBootstrap.tagsSnapshot[SentryTagKeys.decryptionFailure],
          'no_key');
    });
  });

  group('EndpointRaceController wire endpoint.race_attempts', () {
    test('raceApi 递增 race_attempts tag', () async {
      final reachable = {'https://b.example.com'};
      final c = EndpointRaceController(probe: (e) async => reachable.contains(e));
      await c.raceApi([
        const BootstrapEndpoint(url: 'https://a.example.com'),
        const BootstrapEndpoint(url: 'https://b.example.com'),
      ]);
      expect(SentryBootstrap.tagsSnapshot[SentryTagKeys.endpointRaceAttempts],
          '1');
      await c.raceApi([
        const BootstrapEndpoint(url: 'https://a.example.com'),
        const BootstrapEndpoint(url: 'https://b.example.com'),
      ]);
      expect(SentryBootstrap.tagsSnapshot[SentryTagKeys.endpointRaceAttempts],
          '2');
      c.dispose();
    });
  });

  group('新增 tag 便捷方法（5.7.2 剩余 flavor/auth/connectivity）', () {
    test('tagFlavor / tagAuthState / tagConnectivity', () {
      SentryBootstrap.tagFlavor('brand_a');
      SentryBootstrap.tagAuthState('authenticated');
      SentryBootstrap.tagConnectivity(online: true);
      final t = SentryBootstrap.tagsSnapshot;
      expect(t[SentryTagKeys.flavorId], 'brand_a');
      expect(t[SentryTagKeys.authState], 'authenticated');
      expect(t[SentryTagKeys.connectivityOnline], 'true');
    });
    test('tagConnectivity offline → false', () {
      SentryBootstrap.tagConnectivity(online: false);
      expect(SentryBootstrap.tagsSnapshot[SentryTagKeys.connectivityOnline],
          'false');
    });
  });
}

/// 极简 HttpClientAdapter：任意请求返回给定 JSON map（200）。
class _MapAdapter implements HttpClientAdapter {
  _MapAdapter(this._builder);
  final Map<String, dynamic> Function(Uri uri) _builder;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final json = _builder(options.uri);
    return ResponseBody.fromString(
      _encode(json),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  String _encode(Map<String, dynamic> m) {
    final entries = m.entries.map((e) {
      final v = e.value;
      final encoded = v is String ? '"$v"' : '$v';
      return '"${e.key}":$encoded';
    }).join(',');
    return '{$entries}';
  }
}
