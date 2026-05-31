/// W8.1 — WarningBanner：computeWarning 逻辑 + 优先级 + 渲染 + F14 gate。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/warning_banner.dart';

class _MockService extends Mock implements XboardService {}

const _gb = 1024 * 1024 * 1024;

XbDomainSubscription sub({
  required int total,
  required int used,
  DateTime? expiredAt,
}) =>
    XbDomainSubscription(
      email: 'a@b.com', uuid: 'x', totalBytes: total, usedBytes: used,
      expiredAt: expiredAt,
    );

void main() {
  final now = DateTime(2026, 6, 1);

  group('computeWarning 逻辑 + 优先级', () {
    test('超额（已用≥总量）→ overQuota（最高优先）', () {
      final w = computeWarning(sub(total: 10 * _gb, used: 10 * _gb), now: now);
      expect(w, XbWarningKind.overQuota);
    });
    test('流量不足（剩余≤10%）→ trafficLow', () {
      final w = computeWarning(sub(total: 100 * _gb, used: 95 * _gb), now: now);
      expect(w, XbWarningKind.trafficLow);
    });
    test('即将到期（≤3天）→ expiringSoon', () {
      final w = computeWarning(
          sub(total: 100 * _gb, used: 10 * _gb,
              expiredAt: now.add(const Duration(days: 2))),
          now: now);
      expect(w, XbWarningKind.expiringSoon);
    });
    test('健康 → null', () {
      final w = computeWarning(
          sub(total: 100 * _gb, used: 10 * _gb,
              expiredAt: now.add(const Duration(days: 60))),
          now: now);
      expect(w, isNull);
    });
    test('超额优先于到期', () {
      final w = computeWarning(
          sub(total: 10 * _gb, used: 10 * _gb,
              expiredAt: now.add(const Duration(days: 1))),
          now: now);
      expect(w, XbWarningKind.overQuota);
    });
  });

  group('WarningBanner 渲染', () {
    Future<void> pump(WidgetTester t, XbDomainSubscription s) async {
      final service = _MockService();
      when(() => service.getSubscription())
          .thenAnswer((_) async => XbResult.success(s));
      await t.pumpWidget(ProviderScope(
        overrides: [xboardServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: Scaffold(body: WarningBanner())),
      ));
      await t.pump(const Duration(milliseconds: 50));
    }

    testWidgets('超额 → 显示流量用尽文案', (t) async {
      await pump(t, sub(total: 10 * _gb, used: 10 * _gb));
      expect(find.textContaining('流量已用尽'), findsOneWidget);
    });

    testWidgets('健康 → 不显示 banner', (t) async {
      await pump(t, sub(total: 100 * _gb, used: 1 * _gb,
          expiredAt: DateTime(2099)));
      expect(find.byType(Container), findsNothing); // SizedBox.shrink
    });
  });
}
