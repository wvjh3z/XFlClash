import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/plan_list_page.dart';
import 'package:fl_clash/xboard/providers/pending_order_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements XboardService {}

Finder paragraph(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == text,
);

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    testWidgets(
      '$brand plan price shares title baseline above the three-line description',
      (tester) async {
        XboardConfig.bind(
          XboardConfig(
            appName: brand,
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
        addTearDown(tester.view.reset);
        final longLine = '第四行${List.filled(40, '连续长介绍').join()}';
        final lines = ['第一行说明', '第二行说明', '第三行说明', longLine, '第五行不显示'];
        final description = lines.join('\n');
        final service = _Service();
        when(() => service.getPlans()).thenAnswer(
          (_) async => XbSuccess([
            PlanItem(
              id: 1,
              name: '测试套餐 🇭🇰',
              description: lines.map((line) => '<p>$line</p>').join(),
              transferEnableGb: 999,
              prices: const [
                PricePlan(period: XbPlanPeriod.resetTraffic, amountYuan: 1),
                PricePlan(period: XbPlanPeriod.quarterly, amountYuan: 30),
                PricePlan(period: XbPlanPeriod.monthly, amountYuan: 12.5),
              ],
            ),
          ]),
        );
        for (final width in [360.0, 1000.0]) {
          for (final scale in [1.0, 1.4]) {
            tester.view.physicalSize = Size(width, 900);
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
            final intro = paragraph(description);
            final render = tester.renderObject<RenderParagraph>(intro);
            expect(render.maxLines, 3);
            expect(render.overflow, TextOverflow.clip);
            final visibleBoxes = render.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: description.length),
            );
            expect(
              visibleBoxes.map((box) => box.top.toStringAsFixed(2)).toSet(),
              hasLength(3),
            );
            final fifth = description.indexOf('第五行不显示');
            expect(
              render.getBoxesForSelection(
                TextSelection(
                  baseOffset: fifth,
                  extentOffset: description.length,
                ),
              ),
              isEmpty,
            );
            // Even the start of the fourth paragraph is outside the line budget.
            expect(
              render.getBoxesForSelection(
                TextSelection(
                  baseOffset: description.indexOf(longLine),
                  extentOffset: fifth - 1,
                ),
              ),
              isEmpty,
            );
            final titleRect = tester.getRect(paragraph('测试套餐 🇭🇰'));
            final introRect = tester.getRect(intro);
            final priceRect = tester.getRect(paragraph('¥12.50 /月付'));
            expect(titleRect.right, lessThanOrEqualTo(priceRect.left - 11));
            final titleBox = tester.renderObject<RenderBox>(paragraph('测试套餐 🇭🇰'));
            final priceBox = tester.renderObject<RenderBox>(paragraph('¥12.50 /月付'));
            expect(
              titleRect.top + titleBox.getDryBaseline(titleBox.constraints, TextBaseline.alphabetic)!,
              closeTo(priceRect.top + priceBox.getDryBaseline(priceBox.constraints, TextBaseline.alphabetic)!, 1),
            );
            expect(introRect.top, greaterThanOrEqualTo(priceRect.bottom + 6));
            expect(introRect.width, greaterThan(titleRect.width));
            expect(priceRect.right, lessThan(width));
            expect(find.text('999 GB', findRichText: true), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          }
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );
  }
}
