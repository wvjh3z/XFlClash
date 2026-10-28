import 'package:fl_clash/xboard/providers/xboard_connectivity_provider.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fixtures/fake_connectivity.dart';

void main() {
  late ProviderContainer container;
  late FakeConnectivity connectivity;

  setUp(SentryBootstrap.resetForTest);
  tearDown(() async {
    container.dispose();
    await connectivity.close();
    SentryBootstrap.resetForTest();
  });

  void createContainer(FakeConnectivity fake) {
    connectivity = fake;
    container = ProviderContainer(
      overrides: [xboardConnectivityClientProvider.overrideWithValue(fake)],
    );
    // Subscribe to the production stream, replacing only the hardware boundary.
    container.listen(xboardConnectivityProvider, (_, _) {});
  }

  test(
    'initial platform result updates the Sentry tag before publishing stream data',
    () async {
      createContainer(
        FakeConnectivity(initial: const [ConnectivityResult.wifi]),
      );
      expect(await container.read(xboardConnectivityProvider.future), [
        ConnectivityResult.wifi,
      ]);
      expect(
        SentryBootstrap.tagsSnapshot[SentryTagKeys.connectivityOnline],
        'true',
      );
    },
  );

  test(
    'real change stream keeps online tag in sync with each emitted result',
    () async {
      createContainer(FakeConnectivity());
      await container.read(xboardConnectivityProvider.future);
      await pumpEventQueue();

      connectivity.goOffline();
      await pumpEventQueue();
      expect(container.read(xboardConnectivityProvider).requireValue, [
        ConnectivityResult.none,
      ]);
      expect(
        SentryBootstrap.tagsSnapshot[SentryTagKeys.connectivityOnline],
        'false',
      );

      connectivity.goMobile();
      await pumpEventQueue();
      expect(container.read(xboardConnectivityProvider).requireValue, [
        ConnectivityResult.mobile,
      ]);
      expect(
        SentryBootstrap.tagsSnapshot[SentryTagKeys.connectivityOnline],
        'true',
      );

      connectivity.emit(const [
        ConnectivityResult.wifi,
        ConnectivityResult.none,
      ]);
      await pumpEventQueue();
      expect(
        SentryBootstrap.tagsSnapshot[SentryTagKeys.connectivityOnline],
        'false',
      );
    },
  );

  test(
    'initial platform error is unknown then recovers through the stream',
    () async {
      createContainer(_InitiallyFailingConnectivity());
      expect(await container.read(xboardConnectivityProvider.future), isEmpty);
      expect(container.read(isOfflineProvider), isFalse);
      expect(
        SentryBootstrap.tagsSnapshot[SentryTagKeys.connectivityOnline],
        'false',
      );
      await pumpEventQueue();
      connectivity.goWifi();
      await pumpEventQueue();
      expect(container.read(xboardConnectivityProvider).requireValue, [
        ConnectivityResult.wifi,
      ]);
      expect(
        SentryBootstrap.tagsSnapshot[SentryTagKeys.connectivityOnline],
        'true',
      );
    },
  );
}

class _InitiallyFailingConnectivity extends FakeConnectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      throw StateError('controlled platform connectivity failure');
}
