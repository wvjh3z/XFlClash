import 'dart:async';

import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/services/xb_update_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:fl_clash/xboard/services/xboard_lifecycle_observer.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';

import '../../_fixtures/fake_xboard_sdk.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';

class _FakeAppUpdateApi extends Mock implements AppUpdateApi {}

class _MockStopwatch extends Mock implements Stopwatch {}

void main() {
  late FakeXBoardSDK sdk;
  late EndpointRaceController race;
  var base = 'https://api.test';
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

  setUp(() async {
    now = Duration.zero;
    requests = 0;
    clocks = 0;
    respond = () async => null;
    sdk = FakeXBoardSDK();
    base = 'https://api.test';
    when(() => sdk.baseUrl).thenAnswer((_) => base);
    race = EndpointRaceController(
      probe: (_) async => true,
      onApiSwitch: (url) => base = url,
    );
    await race.raceApi([const BootstrapEndpoint(url: 'https://api.test')]);
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

  tearDown(() {
    race.dispose();
    XbUpdateService.debugSetStopwatchFactory(null);
  });

  ProviderContainer makeContainer({bool sdkReady = true}) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(injectedRaceControllerProvider.notifier).set(race);
    if (sdkReady) container.read(xboardSdkProvider.notifier).set(sdk);
    return container;
  }

  group('API readiness and failover', () {
    for (final platform in ['android', 'windows', 'macos', 'linux']) {
      test(
        '$platform early lifecycle resumes wait and coalesce with startup',
        () async {
          race.dispose();
          base = 'https://bootstrap.test';
          race = EndpointRaceController(
            probe: (_) async => true,
            onApiSwitch: (url) => base = url,
          );
          race.beginApiInitialization();
          final container = makeContainer();
          final pending = <Future<void>>[];
          final observer = XboardLifecycleObserver(
            raceController: race,
            isMobileOverride: platform == 'android',
            isWindowsOverride: platform == 'windows',
            onForegroundUpdateCheck: () =>
                pending.add(XbUpdateService.autoCheckThrottled(container)),
          );
          observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
          observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
          pending.add(XbUpdateService.autoCheck(container));
          await Future<void>.delayed(Duration.zero);
          expect(requests, 0);
          await race.raceApi([
            const BootstrapEndpoint(url: 'https://api.test'),
          ]);
          await Future.wait(pending);
          expect(requests, 1);
          observer.dispose();
        },
      );
    }

    test(
      'early resume and cold startup join one request after the API probe',
      () async {
        race.dispose();
        base = 'https://bootstrap.test';
        race = EndpointRaceController(
          probe: (_) async => true,
          onApiSwitch: (url) => base = url,
        );
        race.beginApiInitialization();
        final container = makeContainer();
        final response = Completer<AppUpdateModel?>();
        final entered = Completer<void>();
        respond = () {
          entered.complete();
          return response.future;
        };
        final resume = XbUpdateService.autoCheckThrottled(container);
        final cold = XbUpdateService.autoCheck(container);
        await Future<void>.delayed(Duration.zero);
        expect(requests, 0);
        await race.raceApi([const BootstrapEndpoint(url: 'https://api.test')]);
        await entered.future;
        expect(requests, 1);
        response.complete(null);
        await Future.wait([resume, cold]);
        expect(clocks, 1);
        // Even a later cold-start callback during subscription initialization
        // reuses the completed startup check rather than sending another GET.
        await XbUpdateService.autoCheck(container);
        expect(requests, 1);
        race.finishApiInitialization();
        respond = () async => null;
        await XbUpdateService.check(sdk, endpoints: race);
        expect(requests, 2);
      },
    );

    test(
      'startup without any valid API ends without HTTP or consuming throttle',
      () async {
        race.dispose();
        race = EndpointRaceController(probe: (_) async => false);
        race.beginApiInitialization();
        final pending = XbUpdateService.autoCheckThrottled(makeContainer());
        await race.raceApi([const BootstrapEndpoint(url: 'https://down.test')]);
        race.finishApiInitialization();
        await pending;
        expect(requests, 0);
        expect(clocks, 0);
      },
    );

    test('disposing a pending startup releases waiters without HTTP', () async {
      race.dispose();
      race = EndpointRaceController(probe: (_) async => true);
      race.beginApiInitialization();
      final pending = XbUpdateService.autoCheckThrottled(makeContainer());
      race.dispose();
      await pending;
      expect(requests, 0);
      expect(clocks, 0);
    });

    test(
      'same endpoint or no alternative does not repeat a failing request',
      () async {
        respond = () async => throw StateError('404');
        expect(
          await XbUpdateService.check(sdk, endpoints: race),
          isA<UpdateCheckFailed>(),
        );
        expect(requests, 1);
      },
    );

    test('actual switch to another probed API permits one retry', () async {
      race.seedEndpoints([
        const BootstrapEndpoint(url: 'https://api.test'),
        const BootstrapEndpoint(url: 'https://backup.test'),
      ], []);
      respond = () async {
        if (requests == 1) throw StateError('404');
        return null;
      };
      expect(
        await XbUpdateService.check(sdk, endpoints: race),
        isA<UpdateNotAvailable>(),
      );
      expect(requests, 2);
      expect(base, 'https://backup.test');
    });

    test('failed SDK base switch cannot send to the old placeholder', () async {
      base = 'https://bootstrap.test';
      expect(
        await XbUpdateService.check(sdk, endpoints: race),
        isA<UpdateCheckFailed>(),
      );
      expect(requests, 0);
    });

    test(
      'reset while response is pending does not publish stale updates or throttle',
      () async {
        final response = Completer<AppUpdateModel?>();
        final entered = Completer<void>();
        respond = () {
          entered.complete();
          return response.future;
        };
        final container = makeContainer();
        final pending = XbUpdateService.autoCheckThrottled(container);
        await entered.future;
        XbUpdateService.resetThrottle();
        response.complete(update);
        await pending;
        expect(clocks, 0);
        expect(container.read(availableUpdateProvider), isNull);
      },
    );
  });

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
      expect(
        await XbUpdateService.check(sdk, endpoints: race),
        isA<UpdateNotAvailable>(),
      );
      expect(requests, 2);
      expect(clocks, 0);

      await XbUpdateService.autoCheckThrottled(container);
      expect(requests, 3);
      expect(clocks, 1);

      now = const Duration(hours: 12);
      await XbUpdateService.autoCheck(container);
      expect(
        await XbUpdateService.check(sdk, endpoints: race),
        isA<UpdateNotAvailable>(),
      );
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
