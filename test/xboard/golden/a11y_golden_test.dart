/// W9.4 — a11y golden test 3 处（合规 § D / ι-1）。
///
/// 覆盖：R6 账号信息卡 / R8 套餐价格卡 / R9 订单详情卡。
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
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/order_summary.dart';
import 'package:fl_clash/xboard/models/plan_item.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/account_info_card.dart';
import 'package:fl_clash/xboard/widgets/order_detail_card.dart';
import 'package:fl_clash/xboard/widgets/plan_price_card.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart';

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
final _fixedExpiry = DateTime(2026, 12, 31);
final _fixedReset = DateTime(2026, 6, 15);
final _fixedCreated = DateTime(2026, 5, 1, 10, 30);

XbDomainSubscription get _sub => XbDomainSubscription(
      email: 'alice@example.com',
      uuid: 'uuid-1234',
      planName: 'Pro 高级套餐',
      totalBytes: 100 * 1024 * 1024 * 1024,
      usedBytes: 42 * 1024 * 1024 * 1024,
      expiredAt: _fixedExpiry,
      nextResetAt: _fixedReset,
    );

/// golden 用：无到期/重置日期 → 文案静态（"长期有效"/"不重置"），不依赖 now（确定性）。
const _subStatic = XbDomainSubscription(
  email: 'alice@example.com',
  uuid: 'uuid-1234',
  planName: 'Pro 高级套餐',
  totalBytes: 100 * 1024 * 1024 * 1024,
  usedBytes: 42 * 1024 * 1024 * 1024,
);

const _plan = PlanItem(
  id: 1,
  name: 'Pro 高级套餐',
  description: '全球节点 / 不限速 / 多设备',
  transferEnableGb: 100,
  prices: [
    PricePlan(period: XbPlanPeriod.monthly, amountYuan: 15.00),
    PricePlan(period: XbPlanPeriod.quarterly, amountYuan: 42.00),
    PricePlan(period: XbPlanPeriod.yearly, amountYuan: 158.00),
  ],
);

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

  /// 在固定尺寸 + 指定 textScale + brightness 下渲染 [child]（包 XbBrandTheme）。
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
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
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: XbBrandTheme(
                brandColor: const Color(0xFFD92E1A),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ── R6 账号信息卡 ──
  group('R6 账号信息卡 a11y golden', () {
    Future<void> pumpCard(WidgetTester t, double scale, Brightness b,
        {XbDomainSubscription? sub}) async {
      final service = _MockService();
      when(() => service.getSubscription())
          .thenAnswer((_) async => XbResult.success(sub ?? _subStatic));
      await pump(
        t,
        const AccountInfoCard(),
        textScale: scale,
        brightness: b,
        service: service,
      );
    }

    testWidgets('light 1.0 + golden + contrast', (t) async {
      await pumpCard(t, 1.0, Brightness.light);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(AccountInfoCard),
          matchesGoldenFile('goldens/a11y_account_light_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('dark 1.0 + golden + contrast', (t) async {
      await pumpCard(t, 1.0, Brightness.dark);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(AccountInfoCard),
          matchesGoldenFile('goldens/a11y_account_dark_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('1.5 无溢出', (t) async {
      await pumpCard(t, 1.5, Brightness.light, sub: _sub);
      expect(t.takeException(), isNull);
    });
    testWidgets('2.0 无溢出', (t) async {
      await pumpCard(t, 2.0, Brightness.light, sub: _sub);
      expect(t.takeException(), isNull);
    });
  });

  // ── R8 套餐价格卡 ──
  group('R8 套餐价格卡 a11y golden', () {
    testWidgets('light 1.0 + golden + contrast', (t) async {
      await pump(t, const PlanPriceCard(plan: _plan),
          textScale: 1.0, brightness: Brightness.light);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(PlanPriceCard),
          matchesGoldenFile('goldens/a11y_plan_light_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('dark 1.0 + golden + contrast', (t) async {
      await pump(t, const PlanPriceCard(plan: _plan),
          textScale: 1.0, brightness: Brightness.dark);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(PlanPriceCard),
          matchesGoldenFile('goldens/a11y_plan_dark_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('1.5 无溢出', (t) async {
      await pump(t, const PlanPriceCard(plan: _plan),
          textScale: 1.5, brightness: Brightness.light);
      expect(t.takeException(), isNull);
    });
    testWidgets('2.0 无溢出', (t) async {
      await pump(t, const PlanPriceCard(plan: _plan),
          textScale: 2.0, brightness: Brightness.light);
      expect(t.takeException(), isNull);
    });
  });

  // ── R9 订单详情卡 ──
  group('R9 订单详情卡 a11y golden', () {
    testWidgets('light 1.0 + golden + contrast', (t) async {
      await pump(t, OrderDetailCard(detail: _order),
          textScale: 1.0, brightness: Brightness.light);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(OrderDetailCard),
          matchesGoldenFile('goldens/a11y_order_light_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('dark 1.0 + golden + contrast', (t) async {
      await pump(t, OrderDetailCard(detail: _order),
          textScale: 1.0, brightness: Brightness.dark);
      expect(t.takeException(), isNull);
      await expectLater(find.byType(OrderDetailCard),
          matchesGoldenFile('goldens/a11y_order_dark_1.0.png'));
      await expectLater(t, meetsGuideline(textContrastGuideline));
    });
    testWidgets('1.5 无溢出', (t) async {
      await pump(t, OrderDetailCard(detail: _order),
          textScale: 1.5, brightness: Brightness.light);
      expect(t.takeException(), isNull);
    });
    testWidgets('2.0 无溢出', (t) async {
      await pump(t, OrderDetailCard(detail: _order),
          textScale: 2.0, brightness: Brightness.light);
      expect(t.takeException(), isNull);
    });
  });
}
