import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_expiry_card.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_traffic_notice.dart';
import 'package:fl_clash/xboard/widgets/xb_plan_notice_card.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart';
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart';

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
  void leave() => state = AuthState.unauthenticated;
}

class _Service extends Mock implements XboardService {}

const gb = 1024 * 1024 * 1024;
XbDomainSubscription sub(num percent, {int? id = 7}) => XbDomainSubscription(
  email: 'fixture@example.invalid',
  uuid: 'fixture',
  planId: id,
  planName: '测试套餐',
  totalBytes: 100 * gb,
  usedBytes: (percent * gb).round(),
  expiredAt: DateTime.now().add(const Duration(days: 2)),
);
void brand(String id) => XboardConfig.bind(
  XboardConfig(
    appName: id,
    flavorId: id,
    subscribeUserAgent: 'fixture',
    devApiEndpoint: '',
    devSubscriptionEndpoint: '',
    debug: true,
    kIsTest: true,
    formA: true,
  ),
);

void main() {
  // xbPush deliberately throttles using wall-clock time across routes/tests.
  // Respect that production guard instead of disabling it in widget fixtures.
  setUp(() => Future<void>.delayed(const Duration(milliseconds: 550)));

  test('exact byte thresholds, exhausted, invalid total and negative use', () {
    for (final row in [
      (899, 1000, null),
      (900, 1000, 90),
      (949, 1000, 90),
      (950, 1000, 95),
      (999, 1000, 95),
      (1000, 1000, 100),
      (1200, 1000, 100),
      (0, 0, null),
      (100, -1, null),
      (-1, 100, null),
    ]) {
      expect(trafficNoticeLevel(row.$1, row.$2), row.$3);
    }
  });
  for (final b in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final dark in [false, true]) {
        for (final percent in [90, 94.99, 95, 99.99, 100]) {
          testWidgets(
            '$b $platform dark=$dark used=$percent shared styling and reset',
            (t) async {
              brand(b);
              addTearDown(XboardConfig.resetForTest);
              t.view.devicePixelRatio = 1;
              t.view.physicalSize = Size(
                platform == TargetPlatform.android ? 320 : 1000,
                1000,
              );
              addTearDown(t.view.reset);
              final service = _Service();
              when(
                () => service.getPlans(),
              ).thenAnswer((_) async => const XbSuccess<List<PlanItem>>([]));
              final c = ProviderContainer(
                overrides: [
                  authStateProvider.overrideWith(_Auth.new),
                  userProfileProvider.overrideWith((ref) async => sub(percent)),
                  xboardServiceProvider.overrideWithValue(service),
                ],
              );
              addTearDown(c.dispose);
              await t.pumpWidget(
                UncontrolledProviderScope(
                  container: c,
                  child: MaterialApp(
                    theme: ThemeData(
                      platform: platform,
                      brightness: dark ? Brightness.dark : Brightness.light,
                    ),
                    home: Scaffold(
                      body: XbBrandTheme(
                        brandColor: const Color(0xffd92e1a),
                        child: Column(
                          children: [
                            const XbExpiryCard(),
                            XbTrafficNotice(
                              centered: platform != TargetPlatform.android,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await t.pumpAndSettle();
              expect(find.byType(XbPlanNoticeCard), findsNWidgets(2));
              final card = t.widget<XbPlanNoticeCard>(
                find.descendant(
                  of: find.byType(XbTrafficNotice),
                  matching: find.byType(XbPlanNoticeCard),
                ),
              );
              expect(card.urgent, percent >= 95);
              expect(card.actionLabel, '重置流量');
              expect(
                find.textContaining(
                  '已用 ${((percent * 10).floor() / 10).toStringAsFixed(1)}%',
                ),
                findsOneWidget,
              );
              expect(
                find.text(
                  percent == 100
                      ? '查看套餐，及时补充流量'
                      : '剩余 ${(100 - percent).toStringAsFixed(1)} GB，请留意用量',
                ),
                findsOneWidget,
              );
              expect(t.takeException(), isNull);
              await t.tap(find.text('重置流量'));
              await t.pumpAndSettle();
              expect(
                t
                    .widget<ResetTrafficPage>(find.byType(ResetTrafficPage))
                    .planId,
                7,
              );
              expect(
                find.textContaining('不支持'),
                findsWidgets,
              ); // no reset price must remain a safe empty state
            },
          );
        }
      }
      for (final scenario in [
        'logout',
        'changed-plan',
        'reset-usage',
        'no-plan',
        'loading',
        'error',
      ]) {
        testWidgets('$b $platform click uses current account: $scenario', (
          t,
        ) async {
          brand(b);
          addTearDown(XboardConfig.resetForTest);
          var current = sub(95);
          var fail = false;
          final service = _Service();
          when(
            () => service.getPlans(),
          ).thenAnswer((_) async => const XbSuccess<List<PlanItem>>([]));
          final c = ProviderContainer(
            overrides: [
              authStateProvider.overrideWith(_Auth.new),
              userProfileProvider.overrideWith((ref) async {
                if (fail) throw StateError('fixture');
                return current;
              }),
              xboardServiceProvider.overrideWithValue(service),
            ],
          );
          addTearDown(c.dispose);
          await t.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: const MaterialApp(
                home: Scaffold(
                  body: XbBrandTheme(
                    brandColor: Color(0xffd92e1a),
                    child: XbTrafficNotice(),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          if (scenario == 'logout') {
            (c.read(authStateProvider.notifier) as _Auth).leave();
          } else {
            fail = scenario == 'error';
            current = scenario == 'changed-plan'
                ? sub(95, id: 8)
                : scenario == 'no-plan'
                ? sub(95, id: null)
                : sub(20);
            c.invalidate(userProfileProvider);
            if (scenario != 'loading') {
              try {
                await c.read(userProfileProvider.future);
              } catch (_) {}
            }
          }
          // Invoke the painted callback before the next frame; it must read the new state.
          t.widget<XbPlanNoticeCard>(find.byType(XbPlanNoticeCard)).onTap!();
          await t.pumpAndSettle();
          if (scenario == 'changed-plan') {
            expect(
              t.widget<ResetTrafficPage>(find.byType(ResetTrafficPage)).planId,
              8,
            );
          } else {
            expect(find.byType(ResetTrafficPage), findsNothing);
            expect(find.byType(XbTrafficNotice), findsOneWidget);
          }
          expect(t.takeException(), isNull);
        });
      }
      for (final periods in [
        [XbPlanPeriod.monthly, XbPlanPeriod.yearly],
        [XbPlanPeriod.monthly],
        [XbPlanPeriod.onetime],
      ]) {
        testWidgets('$b $platform direct renewal $periods', (t) async {
          brand(b);
          addTearDown(XboardConfig.resetForTest);
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = const Size(1000, 1100);
          addTearDown(t.view.reset);
          final plan = PlanItem(
            id: 7,
            name: '测试套餐',
            transferEnableGb: 100,
            prices: [
              for (final p in periods) PricePlan(period: p, amountYuan: 100),
            ],
          );
          final service = _Service();
          when(
            () => service.getPlans(),
          ).thenAnswer((_) async => XbSuccess([plan]));
          await t.pumpWidget(
            ProviderScope(
              overrides: [
                authStateProvider.overrideWith(_Auth.new),
                userProfileProvider.overrideWith((ref) async => sub(95)),
                xboardServiceProvider.overrideWithValue(service),
              ],
              child: MaterialApp(
                theme: ThemeData(platform: platform),
                home: const Scaffold(
                  body: XbBrandTheme(
                    brandColor: Color(0xffd92e1a),
                    child: XbExpiryCard(),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          await t.tap(find.text('去续费'));
          await t.pumpAndSettle();
          expect(find.byType(PlanRenewLoader), findsOneWidget);
          expect(
            t.widget<PlanDetailPage>(find.byType(PlanDetailPage)).renew,
            isTrue,
          );
          final options = t
              .widgetList<XbSelectableOption>(find.byType(XbSelectableOption))
              .toList();
          expect(options.where((o) => o.selected).length, 1);
          expect(
            options.last.selected,
            isTrue,
          ); // monthly+yearly sorted, or sole purchasable period
          expect(t.takeException(), isNull);
        });
      }
    }
  }
}
