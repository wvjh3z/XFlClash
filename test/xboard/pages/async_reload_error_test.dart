import 'dart:async';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/order_list_page.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/pages/plan_list_page.dart';
import 'package:fl_clash/xboard/providers/pending_order_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/xb_async_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements XboardService {}

enum _Page { orders, plans, renew }

class _Harness {
  _Harness(this.page, this.brand) {
    when(() => service.getPlans()).thenAnswer((_) {
      final gate = Completer<XbResult<List<PlanItem>>>();
      plans.add(gate);
      return gate.future;
    });
    when(
      () => service.getOrders(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        forceRefresh: any(named: 'forceRefresh'),
      ),
    ).thenAnswer((_) {
      final gate = Completer<XbResult<XbPagedList<OrderSummary>>>();
      orders.add(gate);
      return gate.future;
    });
  }
  final _Page page;
  final String brand;
  final service = _Service();
  final plans = <Completer<XbResult<List<PlanItem>>>>[];
  final orders = <Completer<XbResult<XbPagedList<OrderSummary>>>>[];
  int get count => page == _Page.orders ? orders.length : plans.length;
  String get name => brand == 'brand_a' ? 'OmoFly' : '袋鼠加速';
  String get successText => page == _Page.orders ? '暂无订单记录' : '$name 测试套餐';

  Future<void> mount(WidgetTester tester, TargetPlatform platform) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = platform == TargetPlatform.android
        ? const Size(430, 960)
        : const Size(1280, 960);
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
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      XboardConfig.resetForTest();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          xboardServiceProvider.overrideWithValue(service),
          pendingOrderProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          home: switch (page) {
            _Page.orders => const OrderListPage(),
            _Page.plans => const PlanListPage(),
            _Page.renew => const PlanRenewLoader(planId: 7),
          },
        ),
      ),
    );
    await tester.pump();
    expect(count, 1);
  }

  void fail(int index, {bool unexpected = false}) {
    const error = XbNetwork(XbNetworkKind.timeout, 'fixture timeout');
    if (page == _Page.orders) {
      if (unexpected) {
        orders[index].completeError(StateError('fixture transport throw'));
      } else {
        orders[index].complete(XbResult.failure(error));
      }
    } else {
      if (unexpected) {
        plans[index].completeError(StateError('fixture transport throw'));
      } else {
        plans[index].complete(XbResult.failure(error));
      }
    }
  }

  void succeed(int index) {
    if (page == _Page.orders) {
      orders[index].complete(
        XbResult.success(
          const XbPagedList<OrderSummary>(
            items: [],
            page: 1,
            pageSize: 20,
            total: 0,
          ),
        ),
      );
    } else {
      plans[index].complete(
        XbResult.success([
          PlanItem(
            id: 7,
            name: successText,
            transferEnableGb: 100,
            prices: [
              const PricePlan(period: XbPlanPeriod.monthly, amountYuan: 10),
            ],
          ),
        ]),
      );
    }
  }
}

Future<void> settleView(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

XbAsyncView view(WidgetTester tester) =>
    tester.widget<XbAsyncView>(find.byType(XbAsyncView).first);

void _platformTest(
  String name,
  TargetPlatform platform,
  WidgetTesterCallback body,
) {
  testWidgets(name, body, variant: TargetPlatformVariant({platform}));
}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final page in _Page.values) {
        _platformTest(
          '$brand ${platform.name} ${page.name}: retry failure stays in UI then recovers',
          platform,
          (tester) async {
            final h = _Harness(page, brand);
            await h.mount(tester, platform);
            h.fail(0);
            await settleView(tester);
            expect(view(tester).error, isA<XbNetwork>());
            await tester.tap(find.text('重试').first);
            await tester.pump();
            expect(h.count, 2);
            expect(view(tester).retrying, isTrue);
            h.fail(1);
            await settleView(tester);
            expect(view(tester).retrying, isFalse);
            expect(view(tester).error, isA<XbNetwork>());
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('重试').first);
            await tester.pump();
            h.succeed(2);
            await settleView(tester);
            expect(
              find.textContaining(h.successText, findRichText: true),
              findsWidgets,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
    for (final page in _Page.values) {
      _platformTest(
        '$brand ${page.name}: disposed retry consumes a late failure',
        TargetPlatform.android,
        (tester) async {
          final h = _Harness(page, brand);
          await h.mount(tester, TargetPlatform.android);
          h.fail(0);
          await settleView(tester);
          await tester.tap(find.text('重试').first);
          await tester.pump();
          await tester.pumpWidget(const SizedBox());
          h.fail(1, unexpected: true);
          await settleView(tester);
          expect(tester.takeException(), isNull);
        },
      );
      for (final olderFinishesFirst in [true, false]) {
        _platformTest(
          '$brand ${page.name}: overlapping retry oldFirst=$olderFinishesFirst',
          TargetPlatform.windows,
          (tester) async {
            final h = _Harness(page, brand);
            await h.mount(tester, TargetPlatform.windows);
            h.fail(0);
            await settleView(tester);
            final retry = view(tester).onRetry;
            retry();
            retry();
            await tester.pump();
            expect(h.count, 3);
            if (olderFinishesFirst) {
              h.fail(1);
              await settleView(tester);
              expect(view(tester).retrying, isTrue);
            }
            h.succeed(2);
            await settleView(tester);
            expect(
              find.textContaining(h.successText, findRichText: true),
              findsWidgets,
            );
            if (!olderFinishesFirst) {
              h.fail(1);
              await settleView(tester);
            }
            expect(
              find.textContaining(h.successText, findRichText: true),
              findsWidgets,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      _platformTest(
        '$brand ${platform.name}: pull refresh completes only after its request',
        platform,
        (tester) async {
          final h = _Harness(_Page.orders, brand);
          await h.mount(tester, platform);
          h.succeed(0);
          await settleView(tester);
          var finished = false;
          final refresh = tester
              .widget<RefreshIndicator>(find.byType(RefreshIndicator))
              .onRefresh();
          refresh.then((_) {
            finished = true;
          });
          await tester.pump();
          expect(finished, isFalse);
          expect(h.count, 2);
          h.fail(1);
          await settleView(tester);
          await refresh;
          expect(finished, isTrue);
          expect(view(tester).error, isA<XbNetwork>());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
