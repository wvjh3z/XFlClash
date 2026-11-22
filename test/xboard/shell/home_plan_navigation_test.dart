import 'dart:async';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/pages/reset_traffic_page.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_traffic_notice.dart';

/// 真实壳层：两品牌窄/宽布局都经商店处理首页和节点购买意图。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart'
    show PatchClashConfig, Group, Proxy, ProxiesTabState;
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/providers.dart'
    show selectedMapProvider, groupsProvider, currentProfileProvider;
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart'
    show bootstrapReadyProvider, xboardServiceProvider;
import 'package:fl_clash/xboard/shell/xboard_app_shell.dart';
import 'package:fl_clash/xboard/shell/tabs/shop/shop_tab.dart';
import 'package:fl_clash/xboard/shell/widgets/xb_bottom_bar.dart';
import 'package:fl_clash/xboard/shell/widgets/xb_nav_rail.dart';

import '_net_detection_stub.dart';

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

class _Service extends Mock implements XboardService {}

final _mobileProvider = NotifierProvider<_Mobile, bool>(_Mobile.new);

class _Mobile extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool mobile) => state = mobile;
}

void main() {
  setUpAll(() => registerFallbackValue(XbPlanPeriod.monthly));
  setUp(() => Future<void>.delayed(const Duration(milliseconds: 550)));
  for (final brand in ['brand_a', 'brand_b']) {
    for (final mobile in [true, false]) {
      for (final action in ['去续费', '前往续费 / 购买', '重置流量']) {
        testWidgets('$brand mobile=$mobile actual shell $action', (t) async {
          t.view.physicalSize = Size(mobile ? 390 : 1280, 1000);
          t.view.devicePixelRatio = 1.0;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);

          XboardConfig.bind(
            XboardConfig(
              flavorId: brand,
              appName: brand,
              subscribeUserAgent: 'x',
              devApiEndpoint: 'https://x',
              devSubscriptionEndpoint: 'https://x',
              debug: false,
              kIsTest: true,
              formA: true,
            ),
          );
          addTearDown(XboardConfig.resetForTest);

          const groups = [
            Group(
              type: GroupType.URLTest,
              name: '优选',
              now: 'a',
              all: [Proxy(name: 'a', type: 'ss')],
            ),
          ];
          final service = _Service();
          final catalog = Completer<XbResult<List<PlanItem>>>();
          when(service.getPlans).thenAnswer((_) => catalog.future);
          final container = ProviderContainer(
            overrides: [
              xboardServiceProvider.overrideWithValue(service),
              isMobileViewProvider.overrideWith(
                (ref) => ref.watch(_mobileProvider),
              ),
              authStateProvider.overrideWith(
                () => _FakeAuth(AuthState.authenticated),
              ),
              isStartProvider.overrideWith((ref) => true),
              proxiesTabStateProvider.overrideWith(
                (ref) => const ProxiesTabState(
                  groups: groups,
                  currentGroupName: '优选',
                  proxyCardType: ProxyCardType.standard,
                ),
              ),
              netDetectionOverride(),
              userProfileProvider.overrideWith(
                (ref) => Future.value(
                  XbDomainSubscription(
                    email: 'u@e.com',
                    uuid: 'x',
                    planName: '标准套餐 · VIP',
                    totalBytes: 250 * 1024 * 1024 * 1024,
                    usedBytes: 240 * 1024 * 1024 * 1024,
                    expiredAt: DateTime.now().subtract(const Duration(days: 1)),
                    planId: 6,
                  ),
                ),
              ),
              groupsProvider.overrideWithValue(groups),
              selectedMapProvider.overrideWith((ref) => const {'优选': 'a'}),
              currentProfileProvider.overrideWith((ref) => null),
              patchClashConfigProvider.overrideWithBuild(
                (ref, _) => const PatchClashConfig(mode: Mode.rule),
              ),
            ],
          );
          addTearDown(container.dispose);
          container.read(_mobileProvider.notifier).set(mobile);
          container.read(bootstrapReadyProvider.notifier).set(true);
          container.read(coreStatusProvider.notifier).value =
              CoreStatus.connected;

          final eb = ErrorWidget.builder;
          try {
          await t.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(home: XboardAppShell()),
            ),
          );
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
          expect(find.byType(XbTrafficNotice), findsOneWidget);
          expect(find.textContaining('已用 96.0%'), findsOneWidget);
          if (action == '前往续费 / 购买') {
            await t.tap(find.text('节点'));
            await t.pump();
            await t.pump(const Duration(milliseconds: 400));
          }
          await t.tap(find.text(action));
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
          if (action != '重置流量') {
            expect(find.byType(ShopTab), findsOneWidget);
            final currentIndex = mobile
                ? t.widget<XbBottomBar>(find.byType(XbBottomBar)).currentIndex
                : t.widget<XbNavRail>(find.byType(XbNavRail)).currentIndex;
            expect(currentIndex, 2);
            final title = find.byKey(const ValueKey('shop-plan-title-6'));
            expect(title, findsNothing);
            catalog.complete(
              XbSuccess([
                for (var id = 1; id <= 6; id++)
                  PlanItem(
                    id: id,
                    name: '目录套餐 $id',
                     transferEnableGb: 250,
                     description: List.filled(4, '<p>服务说明</p>').join(),
                     prices: const [
                       PricePlan(period: XbPlanPeriod.monthly, amountYuan: 25),
                       PricePlan(period: XbPlanPeriod.yearly, amountYuan: 270),
                     ],
                  ),
              ]),
            );
            await t.pumpAndSettle();
            expect(title.hitTestable(), findsOneWidget);
             expect(
               FocusManager.instance.primaryFocus?.context?.widget.key,
               const ValueKey('shop-plan-title-6'),
             );
             expect(
               find.text('购买 目录套餐 6', findRichText: true),
               findsOneWidget,
             );
             expect(find.byType(PlanDetailPage), findsNothing);
             expect(find.byType(AlertDialog), findsNothing);
             if (action == '去续费') {
               final year = find.byKey(
                 const ValueKey(('shop-period', 6, XbPlanPeriod.yearly)),
               );
               await t.ensureVisible(year);
               await t.tap(year);
               await t.pumpAndSettle();
               final before = t.state(find.byType(ShopTab));
               t.view.physicalSize = Size(mobile ? 1280 : 390, 1000);
               container.read(_mobileProvider.notifier).set(!mobile);
               await t.pumpAndSettle();
               expect(t.state(find.byType(ShopTab)), same(before));
               expect(t.widget<Semantics>(year).properties.selected, isTrue);
               expect(find.byType(PlanDetailPage), findsNothing);
               expect(find.byType(AlertDialog), findsNothing);
             }
             verify(service.getPlans).called(1);
             verifyNever(
               () => service.createOrder(
                 any(),
                 any(),
                 couponCode: any(named: 'couponCode'),
               ),
             );
          } else {
            expect(find.byType(ResetTrafficPage), findsOneWidget);
            expect(
              t.widget<ResetTrafficPage>(find.byType(ResetTrafficPage)).planId,
              6,
            );
          }
           final wideNow = action == '去续费' ? mobile : !mobile;
           expect(
             find.byType(XbNavRail),
             wideNow ? findsOneWidget : findsNothing,
           );
          } finally {
            ErrorWidget.builder = eb;
          }
        });
      }
    }
  }
}
