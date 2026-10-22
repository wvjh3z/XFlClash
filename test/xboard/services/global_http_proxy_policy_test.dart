import 'package:fl_clash/common/constant.dart' show localhost;
import 'package:fl_clash/common/http.dart';
import 'package:fl_clash/models/models.dart'
    show PatchClashConfig, NetworkProps;
import 'package:fl_clash/providers/app.dart' show runTimeProvider;
import 'package:fl_clash/providers/config.dart'
    show patchClashConfigProvider, networkSettingProvider;
import 'package:fl_clash/providers/state.dart'
    show isStartProvider, suspendProvider;
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final remote = Uri.parse('https://api.example.invalid/api/v1/user/info');

  tearDown(() => globalState.isAttach = false);

  test('before attach, initialized runtime state still controls the proxy', () {
    final container = ProviderContainer(
      overrides: [
        networkSettingProvider.overrideWithBuild(
          (_, _) => const NetworkProps(),
        ),
        patchClashConfigProvider.overrideWithBuild(
          (_, _) => const PatchClashConfig(mixedPort: 7890),
        ),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    globalState.isAttach = false;
    expect(FlClashHttpOverrides.findProxyFor(container, remote), 'DIRECT');

    // Auto-run sets runtime before the remaining attach work has completed.
    container.read(runTimeProvider.notifier).value = 0;
    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY localhost:7890',
    );
  });

  test('Xboard retains the host callback existing local-address bypass', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    globalState.isAttach = false;
    expect(
      FlClashHttpOverrides.findProxyFor(
        container,
        Uri(scheme: 'http', host: localhost, path: '/file'),
      ),
      'DIRECT',
    );
  });

  test('global policy follows current connection, pause and mixed port', () {
    var started = true;
    var suspended = false;
    var port = 7890;
    final container = ProviderContainer(
      overrides: [
        networkSettingProvider.overrideWithBuild(
          (_, _) => const NetworkProps(),
        ),
        isStartProvider.overrideWith((_) => started),
        suspendProvider.overrideWith((_) => suspended),
        patchClashConfigProvider.overrideWithBuild(
          (_, _) => PatchClashConfig(mixedPort: port),
        ),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    globalState.isAttach = true;
    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY localhost:7890',
    );

    started = false;
    container.invalidate(isStartProvider);
    expect(FlClashHttpOverrides.findProxyFor(container, remote), 'DIRECT');
    started = true;
    container.invalidate(isStartProvider);
    suspended = true;
    container.invalidate(suspendProvider);
    expect(FlClashHttpOverrides.findProxyFor(container, remote), 'DIRECT');
    suspended = false;
    container.invalidate(suspendProvider);
    port = 1080;
    container.invalidate(patchClashConfigProvider);
    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY localhost:1080',
    );
  });
}
