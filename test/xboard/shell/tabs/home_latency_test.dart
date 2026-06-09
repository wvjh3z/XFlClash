/// 首页延迟独立状态 HomeLatencyProvider + 速度卡显示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/tabs/home/home_latency_provider.dart';
import 'package:fl_clash/xboard/shell/tabs/home/xb_speed_card.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_traffic_adapter.dart';

class _FakeTraffic extends XbTrafficAdapter {
  const _FakeTraffic();
  @override
  XbTraffic currentTraffic(WidgetRef ref) => (down: 0, up: 0);
}

void main() {
  group('HomeLatencyNotifier 状态机', () {
    test('初始 → ms=null, measuring=false', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = c.read(homeLatencyProvider);
      expect(s.ms, isNull);
      expect(s.measuring, isFalse);
    });

    test('startMeasuring → measuring=true，保留上次 ms', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(homeLatencyProvider.notifier);
      n.setResult(120);
      n.startMeasuring();
      final s = c.read(homeLatencyProvider);
      expect(s.measuring, isTrue);
      expect(s.ms, 120, reason: '测速中保留上次值避免闪烁');
    });

    test('setResult(有效值) → ms=值, measuring=false', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(homeLatencyProvider.notifier).setResult(66);
      final s = c.read(homeLatencyProvider);
      expect(s.ms, 66);
      expect(s.measuring, isFalse);
    });

    test('setResult(null/<=0 失败) → 清空 ms', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(homeLatencyProvider.notifier);
      n.setResult(88);
      n.setResult(null);
      expect(c.read(homeLatencyProvider).ms, isNull);
      n.setResult(-1);
      expect(c.read(homeLatencyProvider).ms, isNull);
      n.setResult(0);
      expect(c.read(homeLatencyProvider).ms, isNull);
    });

    test('reset → 回初始', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(homeLatencyProvider.notifier);
      n.setResult(50);
      n.reset();
      expect(c.read(homeLatencyProvider).ms, isNull);
    });
  });

  group('速度卡显示', () {
    Future<void> pump(WidgetTester t, int? latency) async {
      await t.pumpWidget(ProviderScope(
        overrides: [
          xbTrafficAdapterProvider.overrideWithValue(const _FakeTraffic()),
        ],
        child: MaterialApp(
          home: Scaffold(body: XbSpeedCard(latencyMs: latency)),
        ),
      ));
      await t.pump();
    }

    testWidgets('有延迟 → 显示数字 + ms 单位', (t) async {
      await pump(t, 66);
      // 新布局：延迟卡 RichText 拼接「66 ms」。
      expect(find.textContaining('66', findRichText: true), findsOneWidget);
      expect(find.textContaining('ms', findRichText: true), findsOneWidget);
    });

    testWidgets('无延迟(null) → 显示 --', (t) async {
      await pump(t, null);
      expect(find.textContaining('--', findRichText: true), findsOneWidget);
    });
  });
}
