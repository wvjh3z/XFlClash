import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class _Service extends Mock implements XboardService {}

void main() {
  testWidgets(
    'account failure does not restart API round; explicit refresh still works',
    (tester) async {
      final service = _Service();
      var calls = 0;
      when(() => service.getSubscription()).thenAnswer((_) async {
        calls++;
        return const XbFailure(XbServer(405, 'fixture gateway error'));
      });
      final container = ProviderContainer(
        retry: (count, error) => const Duration(milliseconds: 10),
        overrides: [xboardServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      container.listen(
        userProfileProvider,
        (_, next) {},
        fireImmediately: true,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(calls, 1);
      expect(container.read(userProfileProvider).hasError, isTrue);
      container.invalidate(userProfileProvider);
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(calls, 2);
    },
  );
}
