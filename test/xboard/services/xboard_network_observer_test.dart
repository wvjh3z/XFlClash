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
