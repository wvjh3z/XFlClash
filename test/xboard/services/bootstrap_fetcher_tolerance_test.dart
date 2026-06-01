/// W5（激进宽容版） — BootstrapFetcher.parseEnvelopeBytes 多档兼容路径覆盖。
///
/// 安全契约（AES-256-GCM / nonce 12B 拼前 / AAD `xboard-bootstrap-v1`）保持铁律不放宽——
/// 本套测试只验证「外层包装宽容」（HTTP / 编码 / 文本格式），密文一律用 helper 生成的合法 envelope。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/services/bootstrap_fetcher.dart';

import '_bootstrap_crypto_helper.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('parseEnvelopeBytes — JSON envelope 主路径', () {
    test('标准 JSON → json_envelope', () async {
      final env = await validEnvelope();
      final bytes =
          _b(jsonEncode({'schema_version': 1, 'encrypted': env.encrypted}));
      final r = BootstrapFetcher.parseEnvelopeBytes(bytes);
      expect(r, isNotNull);
      expect(r!.parsePath, 'json_envelope');
      expect(r.envelope.encrypted, env.encrypted);
    });

    test('字段名大小写不敏感 (Schema_Version / ENCRYPTED)', () async {
      final env = await validEnvelope();
      final bytes =
          _b(jsonEncode({'Schema_Version': 1, 'ENCRYPTED': env.encrypted}));
      final r = BootstrapFetcher.parseEnvelopeBytes(bytes);
      expect(r?.parsePath, 'json_envelope');
      expect(r?.envelope.encrypted, env.encrypted);
    });

    test('字段别名 (version / payload)', () async {
      final env = await validEnvelope();
      final bytes = _b(jsonEncode({'version': 1, 'payload': env.encrypted}));
      final r = BootstrapFetcher.parseEnvelopeBytes(bytes);
      expect(r?.parsePath, 'json_envelope');
      expect(r?.envelope.encrypted, env.encrypted);
    });

    test('schema_version 缺失 → 默认 1', () async {
      final env = await validEnvelope();
      final bytes = _b(jsonEncode({'encrypted': env.encrypted}));
      final r = BootstrapFetcher.parseEnvelopeBytes(bytes);
      expect(r?.envelope.schemaVersion, 1);
    });

    test('schema_version 字符串 → tryParse', () async {
      final env = await validEnvelope();
      final bytes =
          _b(jsonEncode({'schema_version': '2', 'encrypted': env.encrypted}));
      final r = BootstrapFetcher.parseEnvelopeBytes(bytes);
      expect(r?.envelope.schemaVersion, 2);
    });
  });

  group('parseEnvelopeBytes — BOM / 编码', () {
    test('UTF-8 BOM (Windows 记事本) 自动剥除', () async {
      final env = await validEnvelope();
      final json = jsonEncode({'schema_version': 1, 'encrypted': env.encrypted});
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(json)]);
      final r = BootstrapFetcher.parseEnvelopeBytes(bytes);
      expect(r?.envelope.encrypted, env.encrypted);
    });

    test('首尾空白 / 换行 trim', () async {
      final env = await validEnvelope();
      final bytes = _b(
          '\n\r\n  ${jsonEncode({'schema_version': 1, 'encrypted': env.encrypted})}  \n');
      final r = BootstrapFetcher.parseEnvelopeBytes(bytes);
      expect(r?.envelope.encrypted, env.encrypted);
    });
  });

  group('parseEnvelopeBytes — 裸 base64（worker 简化部署路径）', () {
    test('裸 base64 → raw_base64', () async {
      final env = await validEnvelope();
      final r = BootstrapFetcher.parseEnvelopeBytes(_b(env.encrypted));
      expect(r?.parsePath, 'raw_base64');
      expect(r?.envelope.encrypted, env.encrypted);
    });

    test('PEM 风格分行 base64 → raw_base64（剥换行）', () async {
      final env = await validEnvelope();
      // 每 64 字符一行（PEM 风格）。
      final pem = RegExp('.{1,64}')
          .allMatches(env.encrypted)
          .map((m) => m.group(0))
          .join('\n');
      final r = BootstrapFetcher.parseEnvelopeBytes(_b(pem));
      expect(r?.parsePath, 'raw_base64');
    });

    test('URL-safe base64 (- _) → 自动转标准', () async {
      final env = await validEnvelope();
      final urlsafe = env.encrypted.replaceAll('+', '-').replaceAll('/', '_');
      final r = BootstrapFetcher.parseEnvelopeBytes(_b(urlsafe));
      expect(r?.parsePath, 'raw_base64');
    });

    test('双引号包裹的 base64 → quoted_base64', () async {
      final env = await validEnvelope();
      final r = BootstrapFetcher.parseEnvelopeBytes(_b('"${env.encrypted}"'));
      expect(r?.parsePath, 'quoted_base64');
    });
  });

  group('parseEnvelopeBytes — 包装层', () {
    test('JSONP 包装 callback({...}) → jsonp_wrapped', () async {
      final env = await validEnvelope();
      final inner = jsonEncode({'encrypted': env.encrypted});
      final r = BootstrapFetcher.parseEnvelopeBytes(_b('cb($inner);'));
      expect(r?.parsePath, 'jsonp_wrapped');
    });

    test('HTML <pre> 包裹的 base64 → html_wrapped', () async {
      final env = await validEnvelope();
      final r = BootstrapFetcher.parseEnvelopeBytes(
          _b('<html><body><pre>${env.encrypted}</pre></body></html>'));
      expect(r?.parsePath, 'html_wrapped');
    });
  });

  group('parseEnvelopeBytes — 拒绝路径', () {
    test('空字节 → null', () {
      expect(BootstrapFetcher.parseEnvelopeBytes(Uint8List(0)), isNull);
    });

    test('完全乱码非 base64 / 非 JSON / 非 hex → null', () {
      expect(
        BootstrapFetcher.parseEnvelopeBytes(_b('!@#%^&*()_+={}[]|<>?,./~`')),
        isNull,
      );
    });

    test('过短的合法 base64（< 28 字节 raw）→ null（最小长度护栏）', () {
      // 12B nonce + 16B tag = 28 最小，少于此一定不是合法 envelope。
      final shortB64 = base64.encode(List<int>.filled(20, 1));
      expect(BootstrapFetcher.parseEnvelopeBytes(_b(shortB64)), isNull);
    });

    test('JSON 缺 encrypted 字段 → null', () {
      expect(
        BootstrapFetcher.parseEnvelopeBytes(_b(jsonEncode({'schema_version': 1}))),
        isNull,
      );
    });
  });
}
