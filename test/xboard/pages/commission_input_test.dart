import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/pages/invite_commission_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/providers/invite_provider.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/providers/share_link_provider.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';

class _Service extends Mock implements XboardService {}
class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

void main() {
  testWidgets('返佣首读失败后只读恢复，慢分享不挡主内容，也不自动生成邀请码', (tester) async {
    final service = _Service();
    final share = Completer<XbShareLink>();
    var reads = 0;
    when(service.getInviteInfo).thenAnswer((_) async => ++reads == 1
        ? const XbFailure(XbNetwork(XbNetworkKind.timeout, 'offline'))
        : const XbSuccess(XbInviteInfo(code: null, registeredCount: 3,
            pendingYuan: 0, totalYuan: 1, commissionRate: 5,
            commissionBalanceYuan: 1, accountBalanceYuan: 0)));
    final container = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Auth.new),
      xboardServiceProvider.overrideWithValue(service),
      commissionRecordsProvider.overrideWith((_) async => []),
      shareLinkProvider.overrideWith((_) => share.future),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: const MaterialApp(home: InviteCommissionPage())));
    await tester.pumpAndSettle();
    container.read(networkRecoveryProvider.notifier).publish();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('佣金余额'), findsOneWidget);
    verifyNever(service.generateInviteCode);
    share.completeError(const XbNetwork(XbNetworkKind.timeout, 'offline'));
    await tester.pumpAndSettle();
    expect(find.textContaining('分享链接加载失败'), findsOneWidget);
    expect(find.text('佣金余额'), findsOneWidget);
  });

  test('只读核对与资金操作互斥；核对成功不解除原操作锁', () async {
    final session = CommissionSession(3);
    final outstanding = Completer<void>();
    final first = session.backgroundRead(() => outstanding.future);
    expect(session.acquire(), isTrue);
    var settled = false;
    final ready = session.readersDone.then((_) => settled = true);
    await Future<void>.value();
    expect(settled, isFalse);
    outstanding.complete();
    await first;
    await ready;
    var ran = false;
    final delayed = session.backgroundRead(() async => ran = true);
    await Future<void>.value();
    expect(ran, isFalse);
    session.markUnknown('划转', 29);
    session.release();
    await delayed;
    expect(session.acquire(), isFalse);
    expect(session.acquire(reconciliation: true), isTrue);
    session.release();
    expect(session.acquire(), isFalse);
  });
  for (final (size, expected) in [
    (7, '共 7 条'),
    (commissionRecordsPageSize, '至少 $commissionRecordsPageSize 条'),
    (0, null), // SDK 可能把缺失的 data 折叠为空列表。
    (-1, null), // 接口失败不阻挡记录入口。
  ]) {
    testWidgets('邀请说明使用真实比例，记录入口只显示可核实数量 $size', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          inviteInfoProvider.overrideWith((_) async => const XbInviteInfo(
            code: 'fixture',
            registeredCount: 975,
            pendingYuan: 0,
            totalYuan: 10,
            commissionRate: 37,
            commissionBalanceYuan: 10,
            accountBalanceYuan: 0,
          )),
          shareLinkProvider.overrideWith((_) async =>
              const XbShareLink(enabled: false, primaryUrl: '', backupUrl: '')),
          commissionRecordsProvider.overrideWith((_) async {
            if (size < 0) throw StateError('fixture unavailable');
            return [
              for (var i = 1; i <= size; i++)
                XbCommissionRecord(id: i, getAmountYuan: 1, createdAt: DateTime(2026)),
            ];
          }),
        ],
        child: const MaterialApp(home: InviteCommissionPage()),
      ));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('我的邀请码').first, 160);
      expect(find.text('我的邀请码'), findsOneWidget);
      if (size == 7) {
        final copy = find.text('复制');
        final painted = find.ancestor(of: copy, matching: find.byWidgetPredicate(
          (w) => w is DecoratedBox && w.child is FilledButton && w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).gradient is LinearGradient,
        ));
        expect(painted, findsOneWidget);
        String? copied;
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') copied = call.arguments['text'] as String?;
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
        await tester.ensureVisible(copy);
        await tester.tap(copy);
        await tester.pump();
        expect(copied, 'fixture');
      }
      await tester.scrollUntilVisible(find.text('查看返佣记录'), 320);
      await tester.pumpAndSettle();
      expect(find.textContaining('订单金额 37% 的返佣', findRichText: true), findsOneWidget);
      if (expected == null) {
        expect(find.textContaining(RegExp(r'(共|至少) \d+ 条')), findsNothing);
      } else {
        expect(find.text(expected), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final brand in ['brand_a', 'brand_b']) {
    testWidgets('$brand commission decimal input validation', (tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      XboardConfig.bind(
        XboardConfig(
          appName: brand,
          flavorId: brand,
          subscribeUserAgent: 'fixture',
          devApiEndpoint: '',
          devSubscriptionEndpoint: '',
          debug: true,
          kIsTest: true,
          formA: true,
        ),
      );
      addTearDown(XboardConfig.resetForTest);
      final service = _Service();
      var canReadBalance = false;
      when(service.getInviteInfo).thenAnswer((_) async => !canReadBalance
          ? const XbFailure(XbNetwork(XbNetworkKind.timeout, 'fixture offline'))
          : const XbSuccess(
        XbInviteInfo(code: 'fixture', registeredCount: 0, pendingYuan: 0,
          totalYuan: 10, commissionRate: 10, commissionBalanceYuan: 10,
          accountBalanceYuan: 0),
      ));
      when(() => service.getCommissionRecords(pageSize: commissionRecordsPageSize))
          .thenAnswer((_) async => const XbSuccess(<XbCommissionRecord>[]));
      when(() => service.transferCommissionToBalance(any())).thenAnswer(
        (_) async => const XbFailure(
          XbBusiness(XbBusinessKind.generic, 'fixture rejection', null),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateProvider.overrideWith(_Auth.new),
            xboardServiceProvider.overrideWithValue(service),
            commissionRecordsProvider.overrideWith((_) async => []),
            inviteInfoProvider.overrideWith(
              (ref) async => const XbInviteInfo(
                code: 'fixture',
                registeredCount: 0,
                pendingYuan: 0,
                totalYuan: 10,
                commissionRate: 10,
                commissionBalanceYuan: 10,
                accountBalanceYuan: 0,
              ),
            ),
            shareLinkProvider.overrideWith(
              (ref) async => const XbShareLink(
                enabled: false,
                primaryUrl: '',
                backupUrl: '',
              ),
            ),
          ],
          child: const MaterialApp(home: InviteCommissionPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('划转到余额'));
      await tester.pumpAndSettle();
      expect(find.text('划转金额'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '10.00');
      for (final bad in [
        'NaN',
        'Infinity',
        '1.001',
        '0',
        '-1',
        '1e1',
        '10.01',
      ]) {
        await tester.enterText(find.byType(TextField), bad);
        await tester.tap(find.text('确认划转'));
        await tester.pumpAndSettle();
      }
      verifyNever(() => service.transferCommissionToBalance(any()));
      await tester.enterText(find.byType(TextField), '0.29');
      await tester.tap(find.text('确认划转'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未提交划转'), findsOneWidget);
      verifyNever(() => service.transferCommissionToBalance(any()));
      canReadBalance = true;
      await tester.tap(find.text('确认划转'));
      await tester.pumpAndSettle();
      verify(() => service.transferCommissionToBalance(0.29)).called(1);
      when(() => service.transferCommissionToBalance(0.30)).thenAnswer((_) async =>
          const XbSuccess(true));
      await tester.enterText(find.byType(TextField), '0.30');
      await tester.tap(find.text('确认划转'));
      await tester.pumpAndSettle();
      verify(() => service.transferCommissionToBalance(0.30)).called(1);
      expect(find.text('确认划转'), findsNothing);
      await tester.tap(find.text('划转到余额'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '0.29');
      when(() => service.transferCommissionToBalance(0.29)).thenAnswer((_) async =>
        const XbFailure(XbUnconfirmed('transferCommissionToBalance', 'fixture')));
      await tester.tap(find.text('确认划转'));
      await tester.pumpAndSettle();
      expect(find.textContaining('划转结果尚未确认'), findsOneWidget);
      expect(find.text('确认划转'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('划转到余额'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('只读核对余额和流水'));
      await tester.pumpAndSettle();
      expect(find.textContaining('佣金余额：¥10.00'), findsOneWidget);
      expect(find.text('确认划转'), findsNothing);
      verify(() => service.transferCommissionToBalance(0.29)).called(1);
      verify(() => service.getCommissionRecords(pageSize: commissionRecordsPageSize)).called(1);
      verifyNever(() => service.withdrawCommission(method: any(named: 'method'), account: any(named: 'account')));
      expect(tester.takeException(), isNull);
    });
  }
}
