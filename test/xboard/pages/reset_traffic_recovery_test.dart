import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/pending_order_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/xb_async_view.dart';

class _Service extends Mock implements XboardService {}

const _failed = XbFailure<List<PlanItem>>(
  XbNetwork(XbNetworkKind.timeout, 'fixture timeout'),
);
const _ready = XbSuccess<List<PlanItem>>([
  PlanItem(
    id: 7,
    name: 'fixture',
    transferEnableGb: 10,
    prices: [PricePlan(period: XbPlanPeriod.resetTraffic, amountYuan: 1)],
  ),
]);
void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final scenario in [
        'success',
        'unsupported',
        'dispose-success',
        'dispose-failure',
        'old-first',
        'old-last',
        'latest-failure',
      ]) {
        testWidgets('$brand $platform reset $scenario', (tester) async {
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
          final pending = <Completer<XbResult<List<PlanItem>>>>[];
          when(() => service.getPlans()).thenAnswer((_) {
            final request = Completer<XbResult<List<PlanItem>>>();
            pending.add(request);
            return request.future;
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                xboardServiceProvider.overrideWithValue(service),
                pendingOrderProvider.overrideWith((ref) async => null),
              ],
              child: MaterialApp(
                theme: ThemeData(platform: platform),
                home: const ResetTrafficPage(planId: 7),
              ),
            ),
          );
          await tester.pump();
          pending[0].complete(_failed);
          await tester.pumpAndSettle();
          expect(find.text('重试'), findsOneWidget);
          final retry = tester
              .widget<XbAsyncView>(find.byType(XbAsyncView))
              .onRetry;
          await tester.tap(find.text('重试'));
          await tester.pump();
          expect(pending.length, 2);
          if (scenario.startsWith('dispose')) {
            await tester.pumpWidget(const SizedBox());
            pending[1].complete(
              scenario == 'dispose-success' ? _ready : _failed,
            );
          } else if (scenario.startsWith('old-') ||
              scenario == 'latest-failure') {
            // A second queued retry races the still outstanding previous callback.
            retry();
            await tester.pump();
            expect(pending.length, 3);
            if (scenario == 'old-first') {
              pending[1].complete(_failed);
              await tester.pump();
              expect(
                tester.widget<XbAsyncView>(find.byType(XbAsyncView)).retrying,
                isTrue,
              );
              pending[2].complete(_ready);
            } else {
              pending[2].complete(
                scenario == 'latest-failure' ? _failed : _ready,
              );
              await tester.pumpAndSettle();
              pending[1].complete(
                scenario == 'latest-failure' ? _ready : _failed,
              );
            }
          } else {
            pending[1].complete(
              scenario == 'unsupported' ? const XbSuccess([]) : _ready,
            );
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (scenario.startsWith('dispose')) return;
          if (scenario == 'latest-failure') {
            expect(find.text('重试'), findsOneWidget);
            expect(find.text('流量重置包'), findsNothing);
          } else {
            expect(find.text('重试'), findsNothing);
            expect(
              find.text(
                scenario == 'unsupported' ? '当前套餐不支持单独购买流量重置包' : '流量重置包',
              ),
              findsOneWidget,
            );
          }
        });
      }
    }
  }
}
