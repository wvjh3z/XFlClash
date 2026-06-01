/// W8.5 — XboardConfig.fromEnvironment dart-define 接通（默认值 + AES 解码降级）。
///
/// dart-define 值无法在单测里注入（编译期常量），故测「无注入」默认路径 + bind/current 语义。
/// 真实 dart-define 注入由 build 验证（flutter build --dart-define-from-file=flavor_defines.json）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';

void main() {
  tearDown(XboardConfig.resetForTest);

  group('fromEnvironment 无 dart-define 注入 → 占位默认', () {
    test('endpoint / UA / flavorId 默认值', () {
      final c = XboardConfig.fromEnvironment();
      expect(c.devApiEndpoint, 'https://api.example.com');
      expect(c.devSubscriptionEndpoint, 'https://sub.example.com');
      expect(c.subscribeUserAgent, 'Multi-Platform-Client/v0.1.0 flclash');
      expect(c.flavorId, 'brand_a');
      expect(c.brandColor, 0xFFD92E1A);
    });

    test('bootstrapUrls 默认空 + aesKey 默认 null（降级）', () {
      final c = XboardConfig.fromEnvironment();
      expect(c.bootstrapUrls, isEmpty);
      expect(c.bootstrapAesKeyBytes, isNull);
    });

    test('合规字段默认值', () {
      final c = XboardConfig.fromEnvironment();
      expect(c.termsUrl, 'https://example.com/terms');
      expect(c.privacyUrl, 'https://example.com/privacy');
      expect(c.dataResidency, 'Hong Kong');
      expect(c.dataController, 'Example Tech Co., Ltd.');
      expect(c.supportEmail, 'support@example.com');
    });

    test('UA 含且仅含一个 flclash 子串（F202/F203）', () {
      final ua = XboardConfig.fromEnvironment().subscribeUserAgent.toLowerCase();
      expect('flclash'.allMatches(ua).length, 1);
    });
  });

  group('bind / current / resetForTest 语义', () {
    test('bind 后 current 返回注入实例', () {
      const custom = XboardConfig(
        subscribeUserAgent: 'Custom/1.0 flclash',
        devApiEndpoint: 'https://custom.api',
        devSubscriptionEndpoint: 'https://custom.sub',
        debug: false,
        kIsTest: true,
        flavorId: 'brand_x',
      );
      XboardConfig.bind(custom);
      expect(XboardConfig.current.flavorId, 'brand_x');
      expect(XboardConfig.current.devApiEndpoint, 'https://custom.api');
    });

    test('resetForTest 恢复占位默认', () {
      XboardConfig.bind(const XboardConfig(
        subscribeUserAgent: 'x flclash',
        devApiEndpoint: 'https://x',
        devSubscriptionEndpoint: 'https://x',
        debug: false,
        kIsTest: true,
      ));
      XboardConfig.resetForTest();
      expect(XboardConfig.current.devApiEndpoint, 'https://api.example.com');
    });
  });
}
