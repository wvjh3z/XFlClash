import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/enum/enum.dart' show GroupType;
import 'package:fl_clash/models/models.dart' show Group, Proxy;
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_confirmed_route.dart';

import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:flutter_xboard_sdk/src/core/auth/memory_token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'same-interface node burst switches future GETs without replaying the old GET',
    () async {
      SharedPreferences.setMockInitialValues({});
      final servers = [
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ];
      final urls = [for (final s in servers) 'http://127.0.0.1:${s.port}'];
      final entered = Completer<void>(), release = Completer<void>();
      final hits = <String>[];
      for (final (i, server) in servers.indexed) {
        addTearDown(() => server.close(force: true));
        server.listen((r) async {
          hits.add('$i:${r.method}');
          if (hits.length == 1) {
            entered.complete();
            await release.future;
          }
          r.response.headers.contentType = ContentType.json;
          r.response.write(
            jsonEncode({
              'status': 'success',
              'data': [
                {'id': 1, 'name': 'channel-$i'},
              ],
            }),
          );
          await r.response.close();
        });
      }
      final instance = sdk.XBoardSDK.instance;
      await instance.initialize(
        urls.first,
        customStorage: MemoryTokenStorage(),
      );
      addTearDown(instance.dispose);
      final pageService = XboardServiceImpl(sdk: instance);
      var winner = urls.first, probes = 0;
      final verified = Completer<void>();
      final race = EndpointRaceController(
        vpnActive: true,
        probe: (url) async {
          probes++;
          return url == winner;
        },
        onApiSwitch: instance.switchBaseUrl,
        onVerifiedNetwork: verified.complete,
      );
      addTearDown(race.dispose);
      final candidates = [
        for (final url in urls)
          BootstrapEndpoint(url: url, region: BootstrapRegion.overseas),
      ];
      await race.raceApi(candidates);
      final container = ProviderContainer(
        overrides: [
          isStartProvider.overrideWith((_) => true),
          suspendProvider.overrideWith((_) => false),
          currentProfileIdProvider.overrideWithValue(7),
        ],
      );
      addTearDown(container.dispose);
      final subscription = listenConfirmedNodeChanges(
        container,
        onChange: race.confirmedNodeChanged,
        onReset: race.forgetNodeChange,
      );
      addTearDown(subscription.close);
      void coreReadback(String leaf) {
        container.read(groupsProvider.notifier).value = [
          Group(
            name: 'route',
            type: GroupType.Selector,
            now: leaf,
            all: [
              for (final n in ['one', 'two', 'three'])
                Proxy(name: n, type: 'ss'),
            ],
          ),
        ];
        container.read(xbConfirmedRouteProvider);
      }

      coreReadback('one');
      instance.httpService.configureEndpointRecovery(
        candidates: race.recoveryCandidates,
        onSuccess: race.acceptRecoveredApi,
      );
      race.resetApiEndpointHealth = instance.httpService.resetEndpointHealth;
      final oldRead = pageService.getPaymentMethods();
      await entered.future.timeout(const Duration(seconds: 3));
      try {
        winner = urls.last;
        coreReadback('two');
        coreReadback('three');
        await verified.future.timeout(const Duration(seconds: 3));
        expect(
          probes,
          4,
        ); // Two candidates, one startup round and one coalesced round.
        expect(instance.baseUrl, urls.last);
        expect(
          (await pageService.getPaymentMethods()).dataOrNull!.single.name,
          'channel-1',
        );
      } finally {
        release.complete();
      }
      expect((await oldRead).dataOrNull!.single.name, 'channel-0');
      expect(hits, ['0:GET', '1:GET']);
      expect(instance.baseUrl, urls.last);
    },
  );
}
