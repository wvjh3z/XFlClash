import 'package:fl_clash/xboard/models/plan_item.dart';
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';

class _Service extends Mock implements XboardService {}

const _plan = PlanItem(
  id: 7,
  name: '测试套餐',
  transferEnableGb: 10,
  prices: [
    PricePlan(period: XbPlanPeriod.monthly, amountYuan: 10),
    PricePlan(period: XbPlanPeriod.yearly, amountYuan: 100),
  ],
);
const _coupon = CouponInfo(code: 'VALID', type: 1, value: 100);

void main() {
  setUpAll(() => registerFallbackValue(XbPlanPeriod.monthly));
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final scenario in [
        'dispose-success',
        'dispose-failure',
        'period',
        'edit',
        'selection',
        'composing',
        'pending-submit',
        'empty',
        'reset-only',
      ]) {
        testWidgets('$brand $platform $scenario', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1280, 1100);
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
          final gate = Completer<XbResult<CouponInfo?>>();
          when(
            () => service.checkCoupon(any(), any(), any()),
          ).thenAnswer((_) => gate.future);
          final plan = scenario == 'empty' || scenario == 'reset-only'
              ? PlanItem(
                  id: 7,
                  name: '测试套餐',
                  transferEnableGb: 10,
                  prices: scenario == 'empty'
                      ? []
                      : [
                          const PricePlan(
                            period: XbPlanPeriod.resetTraffic,
                            amountYuan: 1,
                          ),
                        ],
                )
              : _plan;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [xboardServiceProvider.overrideWithValue(service)],
              child: MaterialApp(
                theme: ThemeData(platform: platform),
                home: PlanDetailPage(plan: plan, renew: true),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (scenario == 'empty' || scenario == 'reset-only') {
            expect(find.textContaining('暂无可购买周期'), findsOneWidget);
            expect(find.text('确认续费'), findsNothing);
            expect(tester.takeException(), isNull);
            return;
          }
          await tester.enterText(find.byType(TextField), 'VALID');
          await tester.tap(find.text('验证'));
          await tester.pump();
          if (scenario.startsWith('dispose')) {
            await tester.pumpWidget(const SizedBox());
          } else if (scenario == 'period') {
            await tester.tap(find.byType(XbSelectableOption).first);
            await tester.pump();
          } else if (scenario == 'pending-submit') {
            await tester.tap(find.text('确认续费'), warnIfMissed: false);
            await tester.pump();
            verifyNever(
              () => service.createOrder(
                any(),
                any(),
                couponCode: any(named: 'couponCode'),
              ),
            );
          }
          gate.complete(
            scenario == 'dispose-failure'
                ? const XbFailure(XbNetwork(XbNetworkKind.timeout, 'fixture'))
                : const XbSuccess(_coupon),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (scenario == 'period') expect(find.text('优惠券已应用'), findsNothing);
          if (scenario == 'selection' || scenario == 'composing') {
            expect(find.text('优惠券已应用'), findsOneWidget);
            final field = tester.widget<TextField>(find.byType(TextField));
            field.controller!.value = field.controller!.value.copyWith(
              selection: const TextSelection(baseOffset: 0, extentOffset: 2),
              composing: scenario == 'composing'
                  ? const TextRange(start: 0, end: 2)
                  : TextRange.empty,
            );
            await tester.pump();
            expect(field.controller!.text, 'VALID');
            expect(find.text('优惠券已应用'), findsOneWidget);
          }
          if (scenario == 'edit') {
            expect(find.text('优惠券已应用'), findsOneWidget);
            await tester.enterText(find.byType(TextField), 'OTHER');
            await tester.pump();
            expect(find.text('优惠券已应用'), findsNothing);
          }
        });
      }
    }
  }
}
