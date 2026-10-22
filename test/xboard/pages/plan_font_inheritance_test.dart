import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/plan_list_page.dart';
import 'package:fl_clash/xboard/providers/pending_order_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements XboardService {}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    testWidgets(
      '$brand plan title, description and price retain the platform font',
      (tester) async {
        final name = brand == 'brand_a' ? 'OmoFly' : '袋鼠加速';
        XboardConfig.bind(
          XboardConfig(
            appName: name,
            flavorId: brand,
            formA: true,
            subscribeUserAgent: 'fixture/flclash',
            devApiEndpoint: '',
            devSubscriptionEndpoint: '',
            debug: true,
            kIsTest: true,
          ),
        );
        addTearDown(XboardConfig.resetForTest);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 960);
        addTearDown(tester.view.reset);
        final service = _Service();
        when(() => service.getPlans()).thenAnswer(
          (_) async => XbSuccess([
            PlanItem(
              id: 1,
              name: '$name 套餐 🇭🇰',
              description: '<p>100 GB/月</p>',
              transferEnableGb: 100,
              prices: const [
                PricePlan(period: XbPlanPeriod.monthly, amountYuan: 12.5),
              ],
            ),
          ]),
        );
        for (final scale in [1.0, 1.4]) {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                xboardServiceProvider.overrideWithValue(service),
                pendingOrderProvider.overrideWith((ref) async => null),
              ],
              child: MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: const PlanListPage(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final paragraphs = tester.renderObjectList<RenderParagraph>(
            find.byType(RichText),
          );
          for (final text in ['$name 套餐 🇭🇰', '100 GB/月', '¥12.50 /月付']) {
            final p = paragraphs.singleWhere(
              (p) => p.text.toPlainText() == text,
            );
            expect(
              p.text.style!.fontFamily,
              ThemeData().textTheme.bodyMedium!.fontFamily,
            );
            expect(p.textScaler.scale(10), scale * 10);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );
  }
}
