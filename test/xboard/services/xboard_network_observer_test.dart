import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/xboard_connectivity_provider.dart';
import 'package:fl_clash/xboard/services/xboard_network_observer.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import '../../_fixtures/fake_connectivity.dart';

class _Race extends EndpointRaceController {
  int refreshes = 0;
  _Race() : super(probe: (_) async => true);
  @override
  void refreshRaceInBackground() {
    refreshes++;
  }
}

class _UnknownConnectivity extends FakeConnectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      throw StateError('unavailable platform query');
}

void main() {
  testWidgets('cold start online snapshot preserves reads already in flight', (tester) async {
    final hardware = FakeConnectivity();
    final race = _Race();
    var invalidations = 0;
    race.resetApiEndpointHealth = () => invalidations++;
    final container = ProviderContainer(overrides: [
      isStartProvider.overrideWith((_) => false),
      suspendProvider.overrideWith((_) => false),
      xboardConnectivityClientProvider.overrideWithValue(hardware),
    ]);
    final observer = XboardNetworkObserver(container, race);
    try {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 301));
      expect(invalidations, 0, reason: 'first Wi-Fi sample is not a switch');
      expect(race.refreshes, 1, reason: 'still verify the initial API');
      hardware.goMobile();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 301));
      expect(invalidations, 1);
      expect(race.refreshes, 2);
    } finally {
      observer.dispose();
      race.dispose();
      container.dispose();
      await hardware.close();
    }
  });
  test('接口变化、门户失败均不算恢复；同一地址成功每代只发布一次', () async {
    var reachable = true, recovered = 0, switched = 0;
    final race = EndpointRaceController(probe: (_) async => reachable,
        onVerifiedNetwork: () => recovered++, onApiSwitch: (_) => switched++);
    addTearDown(race.dispose);
    const endpoints = [BootstrapEndpoint(url: 'https://fixture.invalid')];
    await race.raceApi(endpoints);
    race.networkChanged(rerace: false);
    expect(recovered, 0);
    race.armNetworkRecovery();
    reachable = false;
    await race.raceApi(endpoints);
    expect(recovered, 0);
    reachable = true;
    await race.raceApi(endpoints);
    await race.raceApi(endpoints);
    expect(switched, 1);
    expect(recovered, 1);
    race.networkChanged(rerace: false);
    await race.raceApi(endpoints);
    expect(recovered, 1);
    race.armNetworkRecovery();
    await race.raceApi(endpoints);
    expect(recovered, 2);
    // Portal login or Wi-Fi A -> Wi-Fi B may not notify connectivity_plus.
    // A foreground round alone is not success; repeat races consume it once.
    race.armExplicitRecovery();
    reachable = false;
    await race.raceApi(endpoints);
    expect(recovered, 2);
    reachable = true;
    await race.raceApi(endpoints);
    await race.raceApi(endpoints);
    expect(recovered, 3);
    expect(await race.recheckApi(current: () => true), isTrue);
    expect(recovered, 4);
    race.setVpnActive(true, rerace: false);
    await race.raceApi(endpoints);
    expect(recovered, 4);
    race.armNetworkRecovery();
    await race.raceApi(endpoints);
    expect(recovered, 5);
  });
  for (final brand in ['brand_a', 'brand_b']) {
    testWidgets('$brand unknown platform status does not block VPN rerace', (
      tester,
    ) async {
      var running = false;
      final hardware = _UnknownConnectivity();
      final race = _Race();
      final container = ProviderContainer(
        overrides: [
          isStartProvider.overrideWith((_) => running),
          suspendProvider.overrideWith((_) => false),
          xboardConnectivityClientProvider.overrideWithValue(hardware),
        ],
      );
      final observer = XboardNetworkObserver(container, race);
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(container.read(xboardConnectivityProvider).requireValue, isEmpty);
      running = true;
      container.invalidate(isStartProvider);
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 300));
      expect(race.vpnActive, true);
      expect(race.refreshes, 1);
      hardware.goMobile();
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 300));
      expect(race.refreshes, 2);
      observer.dispose();
      race.dispose();
      container.dispose();
      await hardware.close();
      await tester.pump(Duration.zero);
    });

    testWidgets(
      '$brand physical events debounce, pause, recovery and disposal',
      (tester) async {
        var running = false;
        var suspended = false;
        var healthResets = 0;
        final race = _Race()
          ..resetApiEndpointHealth = () {
            healthResets++;
          };
        final hardware = FakeConnectivity();
        final container = ProviderContainer(
          overrides: [
            isStartProvider.overrideWith((_) => running),
            suspendProvider.overrideWith((_) => suspended),
            xboardConnectivityClientProvider.overrideWithValue(hardware),
          ],
        );
        final states = <bool>[];
        final observer = XboardNetworkObserver(
          container,
          race,
          onEffectiveVpnChanged: (_, active) => states.add(active),
        );
        await tester.pump(Duration.zero);
        await tester.pump(Duration.zero);
        await tester.pump(const Duration(milliseconds: 299));
        expect(race.refreshes, 0);
        await tester.pump(const Duration(milliseconds: 1));
        expect(race.refreshes, 1);
        hardware.emit([ConnectivityResult.vpn, ConnectivityResult.wifi]);
        hardware.emit([ConnectivityResult.wifi, ConnectivityResult.wifi]);
        await tester.pump(Duration.zero);
        await tester.pump(const Duration(milliseconds: 300));
        expect(race.refreshes, 1);
        hardware.goMobile();
        hardware.goWifi();
        hardware.goMobile();
        await tester.pump(Duration.zero);
        await tester.pump(const Duration(milliseconds: 300));
        expect(race.refreshes, 2);
        hardware.goWifi();
        await tester.pump(Duration.zero);
        hardware.goOffline();
        await tester.pump(Duration.zero);
        await tester.pump(const Duration(seconds: 1));
        expect(race.refreshes, 2);
        hardware.goMobile();
        await tester.pump(Duration.zero);
        await tester.pump(const Duration(milliseconds: 300));
        expect(race.refreshes, 3);
        running = true;
        container.invalidate(isStartProvider);
        await tester.pump(Duration.zero);
        expect(race.vpnActive, true);
        await tester.pump(const Duration(milliseconds: 300));
        expect(race.refreshes, 4);
        suspended = true;
        container.invalidate(suspendProvider);
        await tester.pump(Duration.zero);
        expect(race.vpnActive, false);
        await tester.pump(const Duration(milliseconds: 300));
        expect(race.refreshes, 5);
        suspended = false;
        container.invalidate(suspendProvider);
        await tester.pump(Duration.zero);
        expect(race.vpnActive, true);
        await tester.pump(const Duration(milliseconds: 300));
        expect(race.refreshes, 6);
        expect(states, [false, true, false, true]);
        expect(healthResets, greaterThan(3));
        hardware.goWifi();
        await tester.pump(Duration.zero);
        observer.dispose();
        observer.dispose();
        await tester.pump(const Duration(seconds: 1));
        expect(race.refreshes, 6);
        hardware.goMobile();
        await tester.pump(Duration.zero);
        expect(race.refreshes, 6);
        race.dispose();
        container.dispose();
        await hardware.close();
        await tester.pump(Duration.zero);
      },
    );
    for (final sub in [false, true]) {
      test(
        '$brand old failover $sub cannot select after network change',
        () async {
          var pendingPhase = false;
          final delayed = Completer<bool>();
          final race = EndpointRaceController(
            probe: (url) => pendingPhase
                ? delayed.future
                : Future.value(url.endsWith('/first')),
          );
          final entries = [
            const BootstrapEndpoint(url: 'https://candidate.invalid/first'),
            const BootstrapEndpoint(url: 'https://candidate.invalid/second'),
          ];
          await (sub ? race.raceSubscription(entries) : race.raceApi(entries));
          pendingPhase = true;
          final pending = sub
              ? race.failOverSubscription()
              : race.failOverApi();
          race.networkChanged(rerace: false);
          delayed.complete(true);
          await pending;
          expect(
            sub ? race.currentSubscriptionEndpoint : race.currentApiEndpoint,
            sub ? isNull : entries.first.url,
          );
          race.dispose();
        },
      );
    }
    for (final sub in [false, true]) {
      test(
        '$brand old ${sub ? 'subscription' : 'API'} probe cannot win after physical change',
        () async {
          final old = Completer<bool>();
          var fresh = false;
          final race = EndpointRaceController(
            probe: (_) => fresh ? Future.value(true) : old.future,
          );
          final entries = [
            const BootstrapEndpoint(url: 'https://candidate.invalid'),
          ];
          final pending = sub
              ? race.raceSubscription(entries)
              : race.raceApi(entries);
          race.networkChanged(rerace: false);
          old.complete(true);
          await pending;
          expect(
            sub ? race.currentSubscriptionEndpoint : race.currentApiEndpoint,
            isNull,
          );
          fresh = true;
          await (sub ? race.raceSubscription(entries) : race.raceApi(entries));
          expect(
            sub ? race.currentSubscriptionEndpoint : race.currentApiEndpoint,
            entries.single.url,
          );
          race.dispose();
        },
      );
    }
  }
}
