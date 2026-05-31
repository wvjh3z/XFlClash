/// W3.11.7 — pendingDestination provider + buildXbRoute 6 路由 + Property 22 序列化等价。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/providers/pending_destination_provider.dart';

void main() {
  group('PendingDestinationNotifier', () {
    late ProviderContainer c;
    setUp(() => c = ProviderContainer());
    tearDown(() => c.dispose());

    test('默认 null', () {
      expect(c.read(pendingDestinationProvider), isNull);
    });

    test('set → 读到目标', () {
      c.read(pendingDestinationProvider.notifier)
          .set(const PendingDestination(XbRoute.plans));
      expect(c.read(pendingDestinationProvider)!.route, XbRoute.plans);
    });

    test('consume → 返回目标并清空（一次性）', () {
      final n = c.read(pendingDestinationProvider.notifier);
      n.set(const PendingDestination(XbRoute.orderDetail, {'tradeNo': 'T1'}));
      final consumed = n.consume();
      expect(consumed!.route, XbRoute.orderDetail);
      expect(consumed.args['tradeNo'], 'T1');
      expect(c.read(pendingDestinationProvider), isNull); // 已清
      expect(n.consume(), isNull); // 再 consume 是 null
    });

    test('clear → 置 null', () {
      final n = c.read(pendingDestinationProvider.notifier);
      n.set(const PendingDestination(XbRoute.account));
      n.clear();
      expect(c.read(pendingDestinationProvider), isNull);
    });
  });

  group('PendingDestination 值相等（Property 22 前提：可序列化值语义）', () {
    test('同 route + 同 args → 相等', () {
      expect(
        const PendingDestination(XbRoute.checkout, {'planId': 3}),
        const PendingDestination(XbRoute.checkout, {'planId': 3}),
      );
    });

    test('不同 route / args → 不等', () {
      expect(
        const PendingDestination(XbRoute.plans),
        isNot(const PendingDestination(XbRoute.orders)),
      );
      expect(
        const PendingDestination(XbRoute.planDetail, {'planId': 1}),
        isNot(const PendingDestination(XbRoute.planDetail, {'planId': 2})),
      );
    });
  });

  group('buildXbRoute 6 路由全覆盖', () {
    for (final route in XbRoute.values) {
      testWidgets('构造 ${route.name} 页面', (t) async {
        late Widget built;
        await t.pumpWidget(MaterialApp(
          home: Builder(builder: (ctx) {
            built = buildXbRoute(route, const {}, ctx);
            return built;
          }),
        ));
        expect(built, isA<Widget>());
        expect(find.byType(Scaffold), findsOneWidget);
      });
    }
  });

  group('Property 22：序列化后反序列化得到等价 widget tree', () {
    testWidgets('同 (route, args) 经 buildXbRoute 两次 → 等价（同类型 + 同渲染）', (t) async {
      const route = XbRoute.orderDetail;
      const args = {'tradeNo': 'ABC123'};

      // 模拟「序列化」：route.name + args（纯可序列化值，不含闭包/context）
      final serialized = {'route': route.name, 'args': args};
      // 「反序列化」：从名字还原 enum
      final restoredRoute =
          XbRoute.values.firstWhere((r) => r.name == serialized['route']);
      final restoredArgs = serialized['args']! as Map<String, Object?>;

      expect(restoredRoute, route);

      Widget? a, b;
      await t.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          a = buildXbRoute(route, args, ctx);
          b = buildXbRoute(restoredRoute, restoredArgs, ctx);
          return a!;
        }),
      ));
      // 等价：同 runtimeType（同一占位/真实页面类型）
      expect(a.runtimeType, b.runtimeType);
      // 反序列化端渲染含 args（证明参数无损传递）
      await t.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => b!)));
      expect(find.textContaining('ABC123'), findsOneWidget);
    });
  });
}
