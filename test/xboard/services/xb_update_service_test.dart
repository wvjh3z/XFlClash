import 'dart:async';

import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/services/xb_update_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';

import '../../_fixtures/fake_xboard_sdk.dart';

class _FakeAppUpdateApi extends Mock implements AppUpdateApi {}

class _MockStopwatch extends Mock implements Stopwatch {}

void main() {
  late FakeXBoardSDK sdk;
  late _FakeAppUpdateApi api;
  late Future<AppUpdateModel?> Function() respond;
  var now = Duration.zero;
  var requests = 0;
  var clocks = 0;

  const update = AppUpdateModel(
    versionCode: int.fromEnvironment('XB_BUILD_NUMBER', defaultValue: 0) + 1,
    versionName: 'next',
    region: 'unknown',
    downloads: [],
    sha256: '',
    changelog: '',
    force: false,
  );

  setUp(() {
    now = Duration.zero;
    requests = 0;
    clocks = 0;
    respond = () async => null;
    sdk = FakeXBoardSDK();
    api = _FakeAppUpdateApi();
    when(() => sdk.appUpdate).thenReturn(api);
    when(
      () => api.checkUpdate(
        platform: any(named: 'platform'),
        abi: any(named: 'abi'),
        currentVersionCode: any(named: 'currentVersionCode'),
      ),
    ).thenAnswer((_) {
      requests++;
      return respond();
    });
    XbUpdateService.debugSetStopwatchFactory(() {
      clocks++;
      Duration? began;
      final clock = _MockStopwatch();
      when(() => clock.start()).thenAnswer((_) {
        began ??= now;
      });
      when(() => clock.elapsed).thenAnswer((_) {
        final start = began;
        return start == null ? Duration.zero : now - start;
      });
      return clock;
    });
  });

  tearDown(() => XbUpdateService.debugSetStopwatchFactory(null));

  ProviderContainer makeContainer({bool sdkReady = true}) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    if (sdkReady) container.read(xboardSdkProvider.notifier).set(sdk);
    return container;
  }

  group('autoCheckThrottled', () {
    test('首次放行，24h 前跳过，恰满和超过 24h 放行，每次成功重新计时', () async {
      final container = makeContainer();

      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);
      expect(clocks, 1);
      expect(container.read(availableUpdateProvider), isNull);

      await XbUpdateService.autoCheckThrottled(container);
      now = const Duration(hours: 24) - const Duration(milliseconds: 1);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);

      now = const Duration(hours: 24);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 2);
      expect(clocks, 2);

      now = const Duration(hours: 48) - const Duration(milliseconds: 1);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 2);

      now = const Duration(hours: 49);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 3);
      expect(clocks, 3);
    });

    test('成功有更新写清单并开始窗口，清单存在时即使到期也跳过', () async {
      final container = makeContainer();
      respond = () async => update;

      await XbUpdateService.autoCheckThrottled(container);
      expect(container.read(availableUpdateProvider), same(update));
      expect(requests, 1);
      expect(clocks, 1);

      container.read(availableUpdateProvider.notifier).clear();
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);
      container.read(availableUpdateProvider.notifier).set(update);

      now = const Duration(days: 2);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);
      expect(clocks, 1);

      container.read(availableUpdateProvider.notifier).clear();
      respond = () async => null;
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 2);
      expect(clocks, 2);
      expect(container.read(availableUpdateProvider), isNull);
    });

    test('其他入口已有清单时跳过，清除后仍可首次检查', () async {
      final container = makeContainer();
      container.read(availableUpdateProvider.notifier).set(update);

      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 0);
      expect(clocks, 0);
      expect(container.read(availableUpdateProvider), same(update));

      container.read(availableUpdateProvider.notifier).clear();
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);
      expect(clocks, 1);
    });

    test('首次检查失败不占窗口，下一次立即重试', () async {
      final container = makeContainer();
      respond = () async => throw StateError('offline');

      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);
      expect(clocks, 0);
      expect(container.read(availableUpdateProvider), isNull);

      respond = () async => null;
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 2);
      expect(clocks, 1);
    });

    test('窗口到期后失败不重新计时，立即重试成功才开始新窗口', () async {
      final container = makeContainer();
      await XbUpdateService.autoCheckThrottled(container);

      now = const Duration(hours: 24);
      respond = () async => throw StateError('offline');
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 2);
      expect(clocks, 1);

      respond = () async => null;
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 3);
      expect(clocks, 2);

      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 3);
    });

    test('检查在途时重复触发不新增请求，成功完成时才开始计时', () async {
      final container = makeContainer();
      final entered = Completer<void>();
      final response = Completer<AppUpdateModel?>();
      respond = () {
        entered.complete();
        return response.future;
      };

      final first = XbUpdateService.autoCheckThrottled(container);
      await entered.future;
      now = const Duration(days: 2);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);
      expect(clocks, 0);

      response.complete(null);
      await first;
      expect(clocks, 1);
      respond = () async => null;
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);

      now += const Duration(hours: 24);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 2);
      expect(clocks, 2);
    });

    test('SDK 未就绪不占窗口或保留在途标志，就绪后可立即检查', () async {
      final container = makeContainer(sdkReady: false);

      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 0);
      expect(clocks, 0);

      container.read(xboardSdkProvider.notifier).set(sdk);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);
      expect(clocks, 1);
    });

    test('resetThrottle 清除成功窗口，下一次立即放行', () async {
      final container = makeContainer();
      await XbUpdateService.autoCheckThrottled(container);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 1);

      XbUpdateService.resetThrottle();
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 2);
      expect(clocks, 2);
    });

    test('冷启动和手动检查不受自动窗口限制，也不创建或推进窗口', () async {
      final container = makeContainer();

      await XbUpdateService.autoCheck(container);
      expect(await XbUpdateService.check(sdk), isA<UpdateNotAvailable>());
      expect(requests, 2);
      expect(clocks, 0);

      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 3);
      expect(clocks, 1);

      now = const Duration(hours: 12);
      await XbUpdateService.autoCheck(container);
      expect(await XbUpdateService.check(sdk), isA<UpdateNotAvailable>());
      expect(requests, 5);
      expect(clocks, 1);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 5);

      now = const Duration(hours: 24);
      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 6);
      expect(clocks, 2);
    });
  });
}
