import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/util/subscription_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Service extends Mock implements XboardService {}

void main() {
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
