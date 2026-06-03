/// W1.6.8 — 5 个基础设施 provider 单测：默认值 + 写入后再读。
///
/// 用独立 ProviderContainer（不碰 FlClash 根容器，design DD-18 测试隔离）。

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/data/xboard_database.dart';
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

  group('R4.6 step2a 订阅同步地基 provider', () {
    test('injectedTokenStorage / injectedRaceController 默认 null', () {
      expect(container.read(injectedTokenStorageProvider), isNull);
      expect(container.read(injectedRaceControllerProvider), isNull);
    });

    test('xboardDatabase provider 可被 override（生产开真实 drift 文件，测试注入内存库）', () {
      final memDb = XboardDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [xboardDatabaseProvider.overrideWithValue(memDb)],
      );
      addTearDown(c.dispose);
      addTearDown(memDb.close);
      expect(c.read(xboardDatabaseProvider), same(memDb));
    });

    test('encryptedSubscriptionService 可构造（用 config 的订阅 key）', () {
      expect(container.read(encryptedSubscriptionServiceProvider), isNotNull);
    });

    test('subscriptionService 未注入 tokenStorage → 抛错（gate 未完成）', () {
      // riverpod 3 把 provider 内抛的 StateError 包成 ProviderException；断言抛错 + 含 gate 文案。
      expect(
        () => container.read(subscriptionServiceProvider),
        throwsA(predicate((e) => e.toString().contains('tokenStorage 注入前'))),
      );
    });
  });
}
