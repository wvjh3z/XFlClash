import 'dart:async';

import 'package:fl_clash/enum/enum.dart' show GroupType, Mode;
import 'package:fl_clash/models/models.dart' show Group, Proxy;
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_confirmed_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the confirmed leaf of the active chain is a route', () {
    Group group(String name, String? now, List<String> members) => Group(
      type: GroupType.Selector,
      name: name,
      now: now,
      all: [for (final member in members) Proxy(name: member, type: 'ss')],
    );
    final root = group('Route', 'Region', ['Region', 'unused']);
    final region = group('Region', 'HK', ['HK', 'JP']);
    expect(xbConfirmedRouteLeaf([root, region], Mode.rule), 'HK');
    expect(
      xbConfirmedRouteLeaf([root, region.copyWith(now: 'JP')], Mode.rule),
      'JP',
    );
    expect(
      xbConfirmedRouteLeaf([root, region.copyWith(now: null)], Mode.rule),
      isNull,
    );
    expect(
      xbConfirmedRouteLeaf([
        root,
        group('Region', 'Route', ['Route']),
      ], Mode.rule),
      isNull,
    );
    expect(xbConfirmedRouteLeaf([root, region], Mode.direct), isNull);
  });

  testWidgets(
    'a later node supersedes an in-flight probe; disposal cancels the timer',
    (t) async {
      var rounds = 0, recoveries = 0, resets = 0;
      final old = Completer<bool>();
      final controller = EndpointRaceController(
        vpnActive: true,
        probe: (_) => ++rounds == 1 ? old.future : Future.value(false),
        onVerifiedNetwork: () => recoveries++,
      )..resetApiEndpointHealth = () => resets++;
      controller.seedEndpoints(const [
        BootstrapEndpoint(url: 'https://a.invalid'),
      ], []);
      controller.confirmedNodeChanged();
      await t.pump(const Duration(milliseconds: 300));
      controller.confirmedNodeChanged();
      old.complete(true);
      await t.pump();
      expect(controller.currentApiEndpoint, isNull);
      await t.pump(const Duration(milliseconds: 300));
      expect(rounds, 2);
      expect(recoveries, 0);
      expect(resets, 0);
      controller.confirmedNodeChanged();
      controller.dispose();
      await t.pump(const Duration(seconds: 1));
      expect(rounds, 2);
    },
  );
}
