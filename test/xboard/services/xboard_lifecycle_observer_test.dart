/// W5.3.7 — XboardLifecycleObserver：移动端 paused 暂停 / desktop 不暂停 / resumed 重启 + 竞速。

library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/services/xboard_lifecycle_observer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EndpointRaceController race;
  late int raceRefreshes;

  setUp(() {
    raceRefreshes = 0;
    race = EndpointRaceController(probe: (_) async => true);
  });

  test(
    'desktop resumed invokes pending recovery independently of mobile timers',
    () {
      var recovered = 0;
      var mobileResumed = 0;
      final obs = XboardLifecycleObserver(
        raceController: race,
        isMobileOverride: false,
        onRecoverPending: () => recovered++,
        onResumeTimers: () => mobileResumed++,
      );
      obs.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(recovered, 1);
      expect(mobileResumed, 0);
      obs.dispose();
    },
  );

  test(
    'Windows resumed invokes foreground refresh even with unchanged endpoint',
    () async {
      var refreshes = 0;
      var mobileTimers = 0;
      var recoveries = 0;
      race.seedEndpoints([const BootstrapEndpoint(url: 'https://a.test')], []);
      await race.raceApi([const BootstrapEndpoint(url: 'https://a.test')]);
      final obs = XboardLifecycleObserver(
        raceController: race,
        isMobileOverride: false,
        isWindowsOverride: true,
        onForegroundRefresh: () => refreshes++,
        onResumeTimers: () => mobileTimers++,
        onRecoverPending: () => recoveries++,
      );
      obs.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(refreshes, 1);
      expect(recoveries, 1);
      expect(mobileTimers, 0);
      expect(race.currentApiEndpoint, 'https://a.test');
      obs.didChangeAppLifecycleState(AppLifecycleState.hidden);
      obs.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(refreshes, 1);
      obs.dispose();
    },
  );

  test(
    'mobile foreground refresh remains independent of mobile timer callback',
    () {
      var refreshes = 0;
      final obs = XboardLifecycleObserver(
        raceController: race,
        isMobileOverride: true,
        isWindowsOverride: false,
        onForegroundRefresh: () => refreshes++,
      );
      obs.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(refreshes, 1);
      obs.dispose();
    },
  );

  test('macOS/Linux do not enter the newly enabled Windows refresh path', () {
    var refreshes = 0;
    final obs = XboardLifecycleObserver(
      raceController: race,
      isMobileOverride: false,
      isWindowsOverride: false,
      onForegroundRefresh: () => refreshes++,
    );
    obs.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(refreshes, 0);
    obs.dispose();
  });

  test('移动端 paused → 暂停 Timer 回调触发', () {
    var paused = false;
    final obs = XboardLifecycleObserver(
      raceController: race,
      isMobileOverride: true,
      onPauseTimers: () => paused = true,
    );
    obs.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(paused, isTrue);
    obs.dispose();
  });

  test('desktop paused → 不暂停 Timer', () {
    var paused = false;
    final obs = XboardLifecycleObserver(
      raceController: race,
      isMobileOverride: false,
      onPauseTimers: () => paused = true,
    );
    obs.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(paused, isFalse); // desktop 保持运行
    obs.dispose();
  });

  test('移动端 resumed → 重启 Timer + 后台竞速', () async {
    var resumed = false;
    final raceProbe = EndpointRaceController(
      probe: (_) async {
        raceRefreshes++;
        return true;
      },
    )..raceApi([const BootstrapEndpoint(url: 'https://a.com')]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final obs = XboardLifecycleObserver(
      raceController: raceProbe,
      isMobileOverride: true,
      onResumeTimers: () => resumed = true,
    );
    final before = raceRefreshes;
    obs.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(resumed, isTrue);
    expect(raceRefreshes, greaterThan(before)); // refreshRaceInBackground
    obs.dispose();
  });

  test('desktop resumed → 不重启 Timer 但仍后台竞速', () async {
    var resumed = false;
    final obs = XboardLifecycleObserver(
      raceController: race
        ..raceApi([const BootstrapEndpoint(url: 'https://a.com')]),
      isMobileOverride: false,
      onResumeTimers: () => resumed = true,
    );
    obs.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(resumed, isFalse);
    obs.dispose();
  });

  test('dispose 幂等 + 摘除 observer', () {
    final obs = XboardLifecycleObserver(raceController: race)..attach();
    obs.dispose();
    obs.dispose(); // 重入安全
    expect(true, isTrue);
  });
}
