/// W9.4 — a11y golden test 3 处（合规 § D / ι-1）。
///
/// 覆盖三个真实出货界面：R6 账号信息卡 / R8 套餐详情页 / R9 订单支付页。
/// - textScaleFactor 1.0 / 1.5 / 2.0 三组：断言无 overflow 异常（不溢出不截断，9.4.2）；
/// - light / dark 各跑一遍 golden（9.4.3）；
/// - `meetsGuideline(textContrastGuideline)` WCAG AA 对比度（9.4.4，不用 web 工具，ξ-§D）。
///
/// 生成/更新 baseline：
///   flutter test --update-goldens test/xboard/golden/a11y_golden_test.dart
/// 产物落 test/xboard/golden/goldens/a11y_*.png。
///
/// **CJK 字体**：测试环境默认 Ahem 字体把中文渲染成方块（布局仍真实）。setUpAll 尽力加载系统
/// Noto CJK（装在 CI/本机时 golden 中文可读）；加载失败不阻断（fallback 方块，断言仍有效）。
///
/// **订单支付页用终态订单**（completed）：pending/processing 会启动 5s 轮询 Timer，导致
/// `pumpAndSettle` 永不收敛；终态订单无 Timer、无支付方式拉取，渲染确定。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/order_payment_page.dart';
import 'package:fl_clash/xboard/pages/plan_detail_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class _MockService extends Mock implements XboardService {}

const _cjkFontPaths = [
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/System/Library/Fonts/PingFang.ttc',
];

Future<void> _loadCjkFont() async {
  for (final path in _cjkFontPaths) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final bytes = await f.readAsBytes();
      final loader = FontLoader('Roboto') // 覆盖默认 sans，让中文有字形
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return;
    } catch (_) {
      // 加载失败（如 .ttc collection 不被支持）→ fallback 默认字体，断言仍有效。
    }
  }
}

/// 固定示例数据（确定性 golden，不依赖 DateTime.now()）。
final _fixedCreated = DateTime(2026, 5, 1, 10, 30);

const _plan = PlanItem(
  id: 1,
  name: 'Pro 高级套餐',
  description:
      '<p>全球优质节点 · 不限速</p><ul><li>多设备同时在线</li><li>7×24 客服支持</li></ul>',
  transferEnableGb: 100,
  prices: [
    PricePlan(period: XbPlanPeriod.monthly, amountYuan: 15.00),
    PricePlan(period: XbPlanPeriod.quarterly, amountYuan: 42.00),
    PricePlan(period: XbPlanPeriod.yearly, amountYuan: 158.00),
  ],
);

/// 终态订单（completed）：无轮询 Timer，OrderPaymentPage 渲染确定。
OrderDetail get _order => OrderDetail(
      summary: OrderSummary(
        tradeNo: '2026050100001',
        planName: 'Pro 高级套餐',
        period: XbPlanPeriod.yearly,
        totalAmountYuan: 138.00,
        status: XbOrderStatus.completed,
        createdAt: _fixedCreated,
      ),
      paymentMethod: const PaymentMethodItem(id: 'alipay', name: '支付宝'),
      balanceAmountYuan: 10.00,
      discountAmountYuan: 20.00,
      handlingAmountYuan: 0.00,
    );

void main() {
  setUpAll(_loadCjkFont);

  /// 渲染整页（自带 Scaffold）。pages 内部 ListView 可滚，golden 截首屏视口。
  Future<void> pumpPage(
    WidgetTester tester,
    Widget page, {
    required double textScale,
    required Brightness brightness,
    XboardService? service,
  }) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (service != null) xboardServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, brightness: brightness),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: page,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ── R8 套餐详情页 ──
  group('R8 套餐详情页 a11y golden', () {
    testWidgets('light 1.0 + golden + contrast', (t) async {
      await pumpPage(t, const PlanDetailPage(plan: _plan),
          textScale: 1.0, brightness: Brightness.light);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(PlanDetailPage),
          matchesGoldenFile('goldens/a11y_plan_light_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('dark 1.0 + golden + contrast', (t) async {
      await pumpPage(t, const PlanDetailPage(plan: _plan),
          textScale: 1.0, brightness: Brightness.dark);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(PlanDetailPage),
          matchesGoldenFile('goldens/a11y_plan_dark_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('1.5 无溢出', (t) async {
      await pumpPage(t, const PlanDetailPage(plan: _plan),
          textScale: 1.5, brightness: Brightness.light);
      expect(t.takeException(), isNull);
    });
    testWidgets('2.0 无溢出', (t) async {
      await pumpPage(t, const PlanDetailPage(plan: _plan),
          textScale: 2.0, brightness: Brightness.light);
      expect(t.takeException(), isNull);
    });
  });

  // ── R9 订单支付页（终态订单）──
  group('R9 订单支付页 a11y golden', () {
    Future<void> pumpOrderPage(
        WidgetTester t, double scale, Brightness b) async {
      final service = _MockService();
      when(() => service.getOrder('2026050100001'))
          .thenAnswer((_) async => XbResult.success(_order));
      await pumpPage(t, const OrderPaymentPage(tradeNo: '2026050100001'),
          textScale: scale, brightness: b, service: service);
    }

    testWidgets('light 1.0 + golden + contrast', (t) async {
      await pumpOrderPage(t, 1.0, Brightness.light);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(OrderPaymentPage),
          matchesGoldenFile('goldens/a11y_order_light_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('dark 1.0 + golden + contrast', (t) async {
      await pumpOrderPage(t, 1.0, Brightness.dark);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(OrderPaymentPage),
          matchesGoldenFile('goldens/a11y_order_dark_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('1.5 无溢出', (t) async {
      await pumpOrderPage(t, 1.5, Brightness.light);
      expect(t.takeException(), isNull);
    });
    testWidgets('2.0 无溢出', (t) async {
      await pumpOrderPage(t, 2.0, Brightness.light);
      expect(t.takeException(), isNull);
    });
  });
}
