/// W1.6.8 — 5 个基础设施 provider 单测：默认值 + 写入后再读。
///
/// 用独立 ProviderContainer（不碰 FlClash 根容器，design DD-18 测试隔离）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  group('默认值（design §E / §I）', () {
    test('apiEndpoint / subscriptionEndpoint 默认 空串', () {
      expect(container.read(apiEndpointProvider), '');
      expect(container.read(subscriptionEndpointProvider), '');
    });

    test('xboardSdk 默认 null（未 initialize）', () {
      expect(container.read(xboardSdkProvider), isNull);
    });

    test('bootstrapReady 默认 false', () {
      expect(container.read(bootstrapReadyProvider), isFalse);
    });

    test('firstLaunch 默认 false', () {
      expect(container.read(firstLaunchProvider), isFalse);
    });
  });

  group('写入后再读（DD-18 写运行期值）', () {
    test('apiEndpoint.set 写值生效', () {
      container.read(apiEndpointProvider.notifier).set('https://api.example.com');
      expect(container.read(apiEndpointProvider), 'https://api.example.com');
    });

    test('subscriptionEndpoint.set 写值生效', () {
      container
          .read(subscriptionEndpointProvider.notifier)
          .set('https://sub.example.com');
      expect(container.read(subscriptionEndpointProvider), 'https://sub.example.com');
    });

    test('bootstrapReady.set true 生效', () {
      container.read(bootstrapReadyProvider.notifier).set(true);
      expect(container.read(bootstrapReadyProvider), isTrue);
    });

    test('firstLaunch.set true 生效', () {
      container.read(firstLaunchProvider.notifier).set(true);
      expect(container.read(firstLaunchProvider), isTrue);
    });
  });
}
