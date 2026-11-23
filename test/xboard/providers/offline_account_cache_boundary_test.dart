import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/util/subscription_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Service extends Mock implements XboardService {}
class _Authenticated extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

void main() {
  test('网络失败保留只读旧资料；恢复成功一次，健康资料不会随每个 epoch 重拉', () async {
    const original = XbDomainSubscription(email: 'a@example.invalid', uuid: 'a', totalBytes: 1, usedBytes: 0);
    final service = _Service();
    var calls = 0;
    when(service.getSubscription).thenAnswer((_) async => ++calls == 2
        ? const XbFailure(XbNetwork(XbNetworkKind.connectionFailed, 'offline'))
        : const XbSuccess(original));
    final c = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Authenticated.new),
      xboardServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(c.dispose);
    final keep = c.listen(userProfileProvider, (_, _) {});
    addTearDown(keep.close);
    expect(await c.read(userProfileProvider.future), original);
    await expectLater(c.refresh(userProfileProvider.future), throwsA(isA<XbNetwork>()));
    expect(c.read(staleAccountDisplayProvider), original);
    c.read(networkRecoveryProvider.notifier).publish();
    expect(await c.read(userProfileProvider.future), original);
    c.read(networkRecoveryProvider.notifier).publish();
    expect(await c.read(userProfileProvider.future), original);
    expect(calls, 3);
    c.read(authStateProvider.notifier).markUnauthenticated();
    expect(c.read(staleAccountDisplayProvider), isNull);
  });
  test('G01 readable offline cache does not recover the production account provider', () async {
    SharedPreferences.setMockInitialValues({});
    const profile = XbDomainSubscription(email: 'fixture@example.invalid', uuid: 'synthetic',
      planId: 1, planName: 'cached-fixture', totalBytes: 100, usedBytes: 1);
    final cache = SubscriptionCache();
    await cache.write(profile, token: 'synthetic-owner');
    expect((await cache.read(token: 'synthetic-owner'))?.planName, 'cached-fixture');
    expect(await cache.read(token: 'different-synthetic-owner'), isNull);
    final service = _Service();
    const error = XbUnexpected('getSubscription', 'synthetic offline service failure');
    when(service.getSubscription).thenAnswer((_) async => const XbFailure(error));
    final container = ProviderContainer(overrides: [xboardServiceProvider.overrideWithValue(service)]);
    addTearDown(container.dispose);
    await expectLater(container.read(userProfileProvider.future), throwsA(same(error)));
    expect(container.read(userProfileProvider).hasError, isTrue);
    expect((await cache.read(token: 'synthetic-owner'))?.planName, 'cached-fixture');
  });
}
