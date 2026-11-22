/// W3.1 — XbConnectOrb 四态渲染 + 禁用/点击单测。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'dart:math' as math;
import 'dart:ui' show ImageByteFormat;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_connect_orb.dart';

Future<void> pumpOrb(
  WidgetTester tester, {
  required bool ready,
  required CoreStatus core,
  required bool isStart,
}) async {
  final container = ProviderContainer(
    overrides: [isStartProvider.overrideWith((ref) => isStart)],
  );
  addTearDown(container.dispose);
  container.read(bootstrapReadyProvider.notifier).set(ready);
  container.read(coreStatusProvider.notifier).value = core;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: Center(child: XbConnectOrb()))),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Android 已连接：3.6秒呼吸，减弱动态、切走和断开时停止', (tester) async {
    final started = StateProvider<bool>((_) => true);
    final container = ProviderContainer(overrides: [
      isStartProvider.overrideWith((ref) => ref.watch(started)),
    ]);
    addTearDown(container.dispose);
    container.read(bootstrapReadyProvider.notifier).set(true);
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    final glow = find.byKey(const ValueKey('home-connected-breath'));
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    double opacity() => tester.widget<FadeTransition>(glow).opacity.value;
    Future<void> mount({bool reduced = false, bool active = true,
        TargetPlatform platform = TargetPlatform.android}) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: platform),
          themeAnimationDuration: Duration.zero,
          home: Builder(builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: TickerMode(enabled: active, child: Scaffold(
              body: SingleChildScrollView(controller: scroll, child: const Column(
                children: [XbConnectOrb(), SizedBox(height: 1400)],
              )),
            )),
          )),
        ),
      ));
      await tester.pump();
    }
    await mount();
    expect(tester.getSize(glow), const Size.square(255));
    expect(tester.getSize(find.byType(XbConnectOrb)), const Size.square(177));
    final low = opacity();
    await tester.pump(const Duration(milliseconds: 1800));
    expect(opacity(), greaterThan(low + 0.2));
    await tester.pump(const Duration(milliseconds: 1800));
    expect(opacity(), closeTo(low, 0.01));
    scroll.jumpTo(400);
    await tester.pump();
    final hidden = opacity();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(opacity(), hidden);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(opacity(), isNot(closeTo(hidden, 0.01)));
    await mount(reduced: true);
    expect(glow, findsNothing);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    await mount(active: false);
    expect(glow, findsNothing);
    await mount();
    expect(glow, findsOneWidget);
    await mount(platform: TargetPlatform.windows);
    expect(glow, findsNothing);
    await mount();
    container.read(started.notifier).state = false;
    await tester.pump();
    expect(glow, findsNothing);
    expect(find.text('未连接'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
  });

  testWidgets('booting → 「准备中」', (tester) async {
    await pumpOrb(tester,
        ready: false, core: CoreStatus.disconnected, isStart: false);
    expect(find.text('准备中'), findsOneWidget);
  });

  testWidgets('Android 减弱动态：静止连接弧保留峰值、透明尾段和柔和内缘', (tester) async {
    final c = ProviderContainer(overrides: [isStartProvider.overrideWith((_) => true)]);
    addTearDown(c.dispose);
    c.read(bootstrapReadyProvider.notifier).set(true);
    c.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!,
      ),
      home: const Scaffold(body: Center(child: XbConnectOrb())),
    )));
    await tester.pumpAndSettle();
    final ring = find.byKey(const ValueKey('home-mobile-progress-ring'));
    final boundary = tester.renderObject<RenderRepaintBoundary>(ring);
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = (await image.toByteData(format: ImageByteFormat.rawRgba))!;
        int alpha(double degrees, double radius) {
          final a = (degrees - 180) * math.pi / 180;
          final x = (image.width / 2 + radius * 2 * math.cos(a)).floor();
          final y = (image.height / 2 + radius * 2 * math.sin(a)).floor();
          return bytes.getUint8((y * image.width + x) * 4 + 3);
        }
        expect(alpha(120, 86.5), greaterThan(225));
        expect(alpha(170, 86.5), inInclusiveRange(40, 170));
        expect(alpha(240, 86.5), lessThan(5));
        expect(alpha(120, 83.5), lessThan(alpha(120, 86.5)));
      } finally {
        image.dispose();
      }
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected → 「未连接」', (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.disconnected, isStart: false);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('点击连接'), findsOneWidget);
  });

  testWidgets('connecting + 冷启动核心预热（isStart=false，无连接意图）→ 「准备中」（防误显连接中）',
      (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.connecting, isStart: false);
    expect(find.text('准备中'), findsOneWidget);
    expect(find.text('连接中'), findsNothing);
  });

  testWidgets('connecting + VPN 已开启（isStart=true，重连）→ 「连接中」', (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.connecting, isStart: true);
    expect(find.text('连接中'), findsOneWidget);
  });

  testWidgets('connected → 「已连接」+ 主题色文字', (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.connected, isStart: true);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('数据已加密保护'), findsOneWidget);
  });

  testWidgets('文案不含技术词（节点/优选/线路/竞速）', (tester) async {
    await pumpOrb(tester,
        ready: true, core: CoreStatus.disconnected, isStart: false);
    for (final w in const ['节点', '优选', '线路', '竞速']) {
      expect(find.textContaining(w), findsNothing);
    }
  });
}
