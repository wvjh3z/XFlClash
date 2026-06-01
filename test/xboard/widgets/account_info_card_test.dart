/// W4.3 — AccountInfoCard：5 字段渲染 + R6.8 + loading/error/success + a11y textScale。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/widgets/account_info_card.dart';

class _MockService extends Mock implements XboardService {}

void main() {
  late _MockService service;
  setUp(() => service = _MockService());

  Future<void> pump(WidgetTester t, {double textScale = 1.0}) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [xboardServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: const SingleChildScrollView(child: AccountInfoCard()),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('success → 渲染邮箱(完整)/套餐/流量/到期/重置', (t) async {
    when(() => service.getSubscription()).thenAnswer((_) async => XbResult.success(
          XbDomainSubscription(
            email: 'alice@example.com',
            uuid: 'uuid1234-x',
            planName: 'Pro 套餐',
            totalBytes: 10 * 1024 * 1024 * 1024,
            usedBytes: 3 * 1024 * 1024 * 1024,
            expiredAt: DateTime.now().add(const Duration(days: 30)),
            nextResetAt: DateTime.now().add(const Duration(days: 5)),
          ),
        ));
    await pump(t);
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('alice@example.com'), findsOneWidget); // 完整邮箱(用户自己的账号,不脱敏)
    expect(find.text('Pro 套餐'), findsOneWidget);
    expect(find.textContaining('GB'), findsWidgets); // 流量
    expect(find.text('套餐到期'), findsOneWidget);
    expect(find.text('流量重置'), findsOneWidget);
  });

  testWidgets('loading → spinner', (t) async {
    when(() => service.getSubscription()).thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return XbResult.success(const XbDomainSubscription(
          email: 'a@b.com', uuid: 'x', totalBytes: 1, usedBytes: 0));
    });
    await pump(t);
    await t.pump(); // 仍 loading
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.pump(const Duration(milliseconds: 250));
  });

  testWidgets('error → 错误占位 + 重试', (t) async {
    when(() => service.getSubscription()).thenAnswer(
        (_) async => XbResult.failure(XbDomainError.network(
            XbNetworkKind.timeout, '网络超时')));
    await pump(t);
    await t.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('网络超时'), findsOneWidget);
  });

  testWidgets('无套餐 → 显示未购买套餐', (t) async {
    when(() => service.getSubscription()).thenAnswer((_) async => XbResult.success(
        const XbDomainSubscription(
            email: 'a@b.com', uuid: 'x', totalBytes: 0, usedBytes: 0)));
    await pump(t);
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('未购买套餐'), findsOneWidget);
  });

  testWidgets('a11y textScale=2.0 不抛溢出异常', (t) async {
    when(() => service.getSubscription()).thenAnswer((_) async => XbResult.success(
        XbDomainSubscription(
            email: 'alice@example.com', uuid: 'uuid1234-x', planName: 'Pro',
            totalBytes: 10 * 1024 * 1024 * 1024, usedBytes: 3 * 1024 * 1024 * 1024,
            expiredAt: DateTime.now().add(const Duration(days: 30)))));
    await pump(t, textScale: 2.0);
    await t.pump(const Duration(milliseconds: 50));
    expect(t.takeException(), isNull); // 无 overflow throw
  });
}
