import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/pages/invite_commission_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/invite_provider.dart';
import 'package:fl_clash/xboard/providers/share_link_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class _Service extends Mock implements XboardService {}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    testWidgets('$brand commission decimal input validation', (tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      XboardConfig.bind(
        XboardConfig(
          appName: brand,
          flavorId: brand,
          subscribeUserAgent: 'fixture',
          devApiEndpoint: '',
          devSubscriptionEndpoint: '',
          debug: true,
          kIsTest: true,
          formA: true,
        ),
      );
      addTearDown(XboardConfig.resetForTest);
      final service = _Service();
      when(() => service.transferCommissionToBalance(any())).thenAnswer(
        (_) async => const XbFailure(
          XbBusiness(XbBusinessKind.generic, 'fixture rejection', null),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            xboardServiceProvider.overrideWithValue(service),
            inviteInfoProvider.overrideWith(
              (ref) async => const XbInviteInfo(
                code: 'fixture',
                registeredCount: 0,
                pendingYuan: 0,
                totalYuan: 10,
                commissionRate: 10,
                commissionBalanceYuan: 10,
                accountBalanceYuan: 0,
              ),
            ),
            shareLinkProvider.overrideWith(
              (ref) async => const XbShareLink(
                enabled: false,
                primaryUrl: '',
                backupUrl: '',
              ),
            ),
          ],
          child: const MaterialApp(home: InviteCommissionPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('划转到余额'));
      await tester.pumpAndSettle();
      for (final bad in [
        'NaN',
        'Infinity',
        '1.001',
        '0',
        '-1',
        '1e1',
        '10.01',
      ]) {
        await tester.enterText(find.byType(TextField), bad);
        await tester.tap(find.text('确认划转'));
        await tester.pumpAndSettle();
      }
      verifyNever(() => service.transferCommissionToBalance(any()));
      await tester.enterText(find.byType(TextField), '0.29');
      await tester.tap(find.text('确认划转'));
      await tester.pumpAndSettle();
      verify(() => service.transferCommissionToBalance(0.29)).called(1);
      expect(tester.takeException(), isNull);
    });
  }
}
