/// BootstrapPayload / BootstrapEndpoint — v2 endpoint 对象 + region 解析 + 规范化（去末尾斜杠等）。
library;

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
      const raw = 'https://us-cn2.x-panel-getip.com/omo/';
      expect(BootstrapPayload.normalizeEndpoint(raw),
          'https://us-cn2.x-panel-getip.com/omo');
    });
  });

  group('BootstrapEndpoint region 解析', () {
    test('overseas / cn 正常解析', () {
      final o = BootstrapEndpoint.fromJson(
          {'url': 'https://a', 'region': 'overseas'});
      final c = BootstrapEndpoint.fromJson({'url': 'https://b', 'region': 'cn'});
      expect(o.region, BootstrapRegion.overseas);
      expect(c.region, BootstrapRegion.cn);
    });

    test('大小写不敏感', () {
      final o = BootstrapEndpoint.fromJson(
          {'url': 'https://a', 'region': 'OVERSEAS'});
      expect(o.region, BootstrapRegion.overseas);
    });

    test('缺 region → unknown', () {
      final e = BootstrapEndpoint.fromJson({'url': 'https://a'});
      expect(e.region, BootstrapRegion.unknown);
    });

    test('非法 region 值 → unknown', () {
      final e =
          BootstrapEndpoint.fromJson({'url': 'https://a', 'region': 'mars'});
      expect(e.region, BootstrapRegion.unknown);
    });

    test('fromDynamic 容错：纯字符串 → url + unknown', () {
      final e = BootstrapEndpoint.fromDynamic('https://legacy.com');
      expect(e.url, 'https://legacy.com');
      expect(e.region, BootstrapRegion.unknown);
    });

    test('fromDynamic 容错：对象正常解析', () {
      final e = BootstrapEndpoint.fromDynamic(
          {'url': 'https://a', 'region': 'cn'});
      expect(e.url, 'https://a');
      expect(e.region, BootstrapRegion.cn);
    });
  });

  group('BootstrapPayload.fromJson（v2 格式）', () {
    test('对象数组 endpoint + region + next_bootstrap_urls', () {
      final p = BootstrapPayload.fromJson({
        'schema_version': 2,
        'api_endpoints': [
          {'url': 'https://api-o.com', 'region': 'overseas'},
          {'url': 'https://api-c.com', 'region': 'cn'},
        ],
        'subscription_endpoints': [
          {'url': 'https://sub.com', 'region': 'cn'},
        ],
        'next_bootstrap_urls': ['https://next-a.com', 'https://next-b.com'],
      });
      expect(p.apiEndpoints.length, 2);
      expect(p.apiEndpoints[0].region, BootstrapRegion.overseas);
      expect(p.apiEndpoints[1].region, BootstrapRegion.cn);
      expect(p.apiUrls, ['https://api-o.com', 'https://api-c.com']);
      expect(p.subscriptionUrls, ['https://sub.com']);
      expect(p.nextBootstrapUrls, ['https://next-a.com', 'https://next-b.com']);
      expect(p.isValid, isTrue);
    });

    test('容错：endpoint 误填纯字符串数组（健壮性兜底）', () {
      final p = BootstrapPayload.fromJson({
        'api_endpoints': ['https://api.com'],
        'subscription_endpoints': ['https://sub.com'],
      });
      expect(p.apiEndpoints.single.url, 'https://api.com');
      expect(p.apiEndpoints.single.region, BootstrapRegion.unknown);
      expect(p.isValid, isTrue);
    });

    test('缺 next_bootstrap_urls → 空列表，不报错', () {
      final p = BootstrapPayload.fromJson({
        'api_endpoints': [
          {'url': 'https://api.com', 'region': 'cn'}
        ],
        'subscription_endpoints': [
          {'url': 'https://sub.com', 'region': 'cn'}
        ],
      });
      expect(p.nextBootstrapUrls, isEmpty);
    });

    test('空 endpoint 列表 → isValid=false', () {
      final p = BootstrapPayload.fromJson({
        'api_endpoints': <dynamic>[],
        'subscription_endpoints': <dynamic>[],
      });
      expect(p.isValid, isFalse);
    });
  });

  group('BootstrapPayload.normalized', () {
    test('endpoint url 规范化 + 丢空 url + next urls trim', () {
      final p = BootstrapPayload(
        apiEndpoints: const [
          BootstrapEndpoint(url: 'https://a/omo/', region: BootstrapRegion.overseas),
          BootstrapEndpoint(url: '  ', region: BootstrapRegion.cn),
          BootstrapEndpoint(url: 'https://b/', region: BootstrapRegion.cn),
        ],
        subscriptionEndpoints: const [
          BootstrapEndpoint(url: 'https://s/sub//', region: BootstrapRegion.cn),
        ],
        nextBootstrapUrls: const ['  https://next.com  ', ''],
      );
      final n = p.normalized();
      expect(n.apiUrls, ['https://a/omo', 'https://b']);
      // region 保留。
      expect(n.apiEndpoints.first.region, BootstrapRegion.overseas);
      expect(n.subscriptionUrls, ['https://s/sub']);
      expect(n.nextBootstrapUrls, ['https://next.com']);
    });
  });
}
