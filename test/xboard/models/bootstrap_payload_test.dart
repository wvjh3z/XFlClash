/// BootstrapPayload.normalizeEndpoint / normalized — endpoint 规范化（去末尾斜杠等）。

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/bootstrap_payload.dart';

void main() {
  group('normalizeEndpoint', () {
    test('去末尾单斜杠（带路径前缀）', () {
      expect(BootstrapPayload.normalizeEndpoint('https://h/omo/'), 'https://h/omo');
    });

    test('去末尾单斜杠（根路径）', () {
      expect(BootstrapPayload.normalizeEndpoint('https://h/'), 'https://h');
    });

    test('去末尾多斜杠', () {
      expect(BootstrapPayload.normalizeEndpoint('https://h/omo///'), 'https://h/omo');
    });

    test('无末尾斜杠原样', () {
      expect(BootstrapPayload.normalizeEndpoint('https://h/omo'), 'https://h/omo');
    });

    test('trim 首尾空白', () {
      expect(BootstrapPayload.normalizeEndpoint('  https://h/omo/  '),
          'https://h/omo');
    });

    test('只剩 scheme 不误删', () {
      expect(BootstrapPayload.normalizeEndpoint('https://'), 'https://');
    });

    test('裸 IP + 末尾斜杠', () {
      expect(BootstrapPayload.normalizeEndpoint('https://223.26.52.196/'),
          'https://223.26.52.196');
    });

    test('空串 → 空串', () {
      expect(BootstrapPayload.normalizeEndpoint(''), '');
      expect(BootstrapPayload.normalizeEndpoint('   '), '');
    });

    test('真实双斜杠根因 case（us-cn2 /omo/）', () {
      // 解出的 endpoint 是 https://us-cn2.x-panel-getip.com/omo/
      // 规范化后 + SDK 拼 /api/v1/... = .../omo/api/v1/...（不再双斜杠）
      const raw = 'https://us-cn2.x-panel-getip.com/omo/';
      expect(BootstrapPayload.normalizeEndpoint(raw),
          'https://us-cn2.x-panel-getip.com/omo');
    });
  });

  group('BootstrapPayload.normalized', () {
    test('两个列表都规范化 + 丢空串', () {
      const p = BootstrapPayload(
        apiEndpoints: ['https://a/omo/', '  ', 'https://b/'],
        subscriptionEndpoints: ['https://s/sub//'],
      );
      final n = p.normalized();
      expect(n.apiEndpoints, ['https://a/omo', 'https://b']);
      expect(n.subscriptionEndpoints, ['https://s/sub']);
    });

    test('已规范化 payload 幂等', () {
      const p = BootstrapPayload(
        apiEndpoints: ['https://a/omo'],
        subscriptionEndpoints: ['https://s'],
      );
      expect(p.normalized(), p);
    });
  });
}
