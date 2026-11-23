import 'dart:async';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_invite.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/pages/invite_commission_page.dart';
import 'package:fl_clash/xboard/pages/withdraw_commission_dialog.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/invite_provider.dart';
import 'package:fl_clash/xboard/providers/network_recovery_provider.dart';
import 'package:fl_clash/xboard/providers/share_link_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements XboardService {}

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;

  void switchAccount() {
    state = AuthState.unauthenticated;
    markAuthenticated();
  }
}

XbInviteInfo _invite(double commission) => XbInviteInfo(
  code: 'fixture',
  registeredCount: 1000,
  pendingYuan: 400,
  totalYuan: 600,
  commissionRate: 10,
  commissionBalanceYuan: commission,
  accountBalanceYuan: 1000,
);

List<XbCommissionRecord> _records(int n) => [
  for (var id = 1; id <= n; id++)
    XbCommissionRecord(
      id: id,
      getAmountYuan: 1,
      createdAt: DateTime(2026, 6, 10),
    ),
];

Future<ProviderContainer> _setup(
  WidgetTester tester,
  _Service service,
  String brand, {
  double paintedBalance = 199.99,
  Size? viewport,
  double textScale = 1,
}) async {
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
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport ?? Size(brand == 'brand_a' ? 390 : 1100, 1000);
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(_Auth.new),
      xboardServiceProvider.overrideWithValue(service),
      inviteInfoProvider.overrideWith((_) async => _invite(paintedBalance)),
      commissionRecordsProvider.overrideWith((_) async => _records(1)),
      shareLinkProvider.overrideWith(
        (_) async => const XbShareLink(
          enabled: false,
          primaryUrl: '',
          backupUrl: '',
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ), home: Row(children: [
        if (brand == 'brand_b') const SizedBox(width: 80),
        Expanded(child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const InviteCommissionPage()))),
      ])),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('佣金提现'), findsOneWidget);
  expect(find.byIcon(Icons.lock), findsNothing);
  await tester.tap(find.text('佣金提现'));
  await tester.pumpAndSettle();
  final dialogContext = tester.element(find.byType(WithdrawCommissionDialog));
  expect(ModalRoute.of(dialogContext)!.navigator, same(Navigator.of(dialogContext, rootNavigator: true)));
  return container;
}

final _dialog = find.byType(WithdrawCommissionDialog);
final _continue = find.widgetWithText(FilledButton, '提交提现申请');
final _submit = find.widgetWithText(FilledButton, '提交申请');

void main() {
  testWidgets('恢复只补失败的提现条件和方式，不能触发申请', (tester) async {
    final service = _Service();
    when(service.getInviteInfo).thenAnswer((_) async => XbSuccess(_invite(200)));
    var reads = 0, methods = 0;
    when(() => service.getCommissionRecords(page: 1, pageSize: 10)).thenAnswer((_) async =>
      ++reads == 1 ? const XbFailure(XbNetwork(XbNetworkKind.timeout, 'offline'))
          : XbSuccess(_records(10)));
    when(service.getWithdrawMethods).thenAnswer((_) async =>
      ++methods == 1 ? const XbFailure(XbNetwork(XbNetworkKind.timeout, 'offline'))
          : const XbSuccess(['USDT-TRC20']));
    final container = await _setup(tester, service, 'brand_a');
    expect(tester.widget<FilledButton>(_continue).onPressed, isNull);
    container.read(networkRecoveryProvider.notifier).publish();
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_continue).onPressed, isNotNull);
    await tester.tap(_continue);
    await tester.pumpAndSettle();
    container.read(networkRecoveryProvider.notifier).publish();
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(reads, 2);
    expect(methods, 2);
    verify(service.getInviteInfo).called(1);
    verifyNever(() => service.withdrawCommission(method: any(named: 'method'), account: any(named: 'account')));
  });
  testWidgets('320dp 大字号提现：金额保留左右列，键盘缩小视口后仍可确认', (tester) async {
    final service = _Service();
    when(() => service.getInviteInfo()).thenAnswer((_) async => XbSuccess(_invite(268.50)));
    when(() => service.getCommissionRecords(page: 1, pageSize: 10))
        .thenAnswer((_) async => XbSuccess(_records(10)));
    when(() => service.getWithdrawMethods())
        .thenAnswer((_) async => const XbSuccess(['USDT-TRC20']));
    await _setup(tester, service, 'brand_a',
        viewport: const Size(320, 640), textScale: 1.4);

    void expectAmountRow(String label) {
      final name = find.descendant(of: _dialog, matching: find.text(label));
      final amount = find.descendant(of: _dialog, matching: find.text('¥268.50'));
      final left = tester.getRect(name);
      final right = tester.getRect(amount);
      expect(left.right, lessThan(right.left));
      expect(left.center.dy, closeTo(right.center.dy, 1));
      final paragraph = tester.renderObject<RenderParagraph>(amount);
      expect(paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 7),
      ).map((box) => box.top).toSet(), hasLength(1));
    }

    expectAmountRow('可用佣金');
    final condition = tester.getRect(find.text('成功邀请 ≥10 次'));
    final result = tester.getRect(find.text('至少 10 次 · 已达标'));
    expect(condition.right, lessThan(result.left));
    expect(condition.center.dy, closeTo(result.center.dy, 1));
    final submitLabel = find.descendant(of: _continue, matching: find.text('提交提现申请'));
    final submitParagraph = tester.renderObject<RenderParagraph>(submitLabel);
    expect(submitParagraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 6),
    ).map((box) => box.top).toSet(), hasLength(1));
    final cancel = find.widgetWithText(FilledButton, '关闭');
    expect(tester.getSize(cancel).width, closeTo(tester.getSize(_continue).width, 0.1));
    await tester.tap(_continue);
    await tester.pumpAndSettle();
    const formLabel = '整笔提现额';
    expectAmountRow(formLabel);
    final nameParagraph = tester.renderObject<RenderParagraph>(find.text(formLabel));
    expect(nameParagraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: formLabel.length),
    ).map((box) => box.top).toSet(), hasLength(1));
    // Measure the rendered field, not the padding formula. A one-dp wider
    // screen used to remove ~80dp of usable content at the 360dp boundary.
    double? previous;
    for (final width in [359.0, 360.0, 361.0, 390.0]) {
      tester.view.physicalSize = Size(width, 640);
      await tester.pumpAndSettle();
      final fieldWidth = tester.getSize(find.ancestor(
        of: find.text(formLabel), matching: find.byType(Table),
      ).first).width;
      if (previous != null) {
        expect(fieldWidth, greaterThanOrEqualTo(previous - .01));
        if (width <= 361) expect(fieldWidth - previous, lessThanOrEqualTo(1.01));
      }
      previous = fieldWidth;
    }
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    final methodLabel = tester.getRect(find.text('收款方式'));
    final accountLabel = tester.getRect(find.text('收款账户'));
    final methodControl = tester.getRect(find.byType(DropdownButton<String>));
    final accountControl = tester.getRect(find.byType(TextField));
    expect(methodLabel.left, closeTo(accountLabel.left, 1));
    expect(methodLabel.right, lessThan(methodControl.left));
    expect(accountLabel.right, lessThan(accountControl.left));
    expect(methodLabel.center.dy, closeTo(methodControl.center.dy, 1));
    expect(accountLabel.center.dy, closeTo(accountControl.center.dy, 1));
    expect(find.text('请选择收款方式'), findsOneWidget);
    expect(find.text('提现门槛 ¥200，申请由人工审核。'), findsOneWidget);
    final confirm = find.byType(CheckboxListTile);
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.getBottomLeft(confirm).dy, lessThanOrEqualTo(tester.getTopLeft(_submit).dy));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USDT-TRC20').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fixture-account');
    tester.view.viewInsets = const FakeViewPadding(bottom: 230);
    await tester.pumpAndSettle();
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(confirm).value, isTrue);
    expect(tester.widget<FilledButton>(_submit).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final brand in ['brand_a', 'brand_b']) {
    for (final (balance, count, statusBalance, statusCount, pass) in [
      (199.99, 9, '未达标', '9 次 · 未达标', false),
      (199.99, 10, '未达标', '至少 10 次 · 已达标', false),
      (200.0, 9, '已达标', '9 次 · 未达标', false),
      (200.0, 10, '已达标', '至少 10 次 · 已达标', true),
      (200.0, 0, '已达标', '无法核实', false),
      (0.0, 10, '无法核实', '至少 10 次 · 已达标', false),
      (null, 10, '无法核实', '至少 10 次 · 已达标', false),
      (200.0, null, '已达标', '无法核实', false),
    ]) {
      testWidgets('$brand independent withdrawal gates $balance / $count', (
        tester,
      ) async {
        final service = _Service();
        when(() => service.getInviteInfo()).thenAnswer(
          (_) async => balance == null
              ? const XbFailure(
                  XbNetwork(XbNetworkKind.timeout, 'fixture timeout'),
                )
              : XbSuccess(_invite(balance)),
        );
        when(
          () => service.getCommissionRecords(page: 1, pageSize: 10),
        ).thenAnswer(
          (_) async => count == null
              ? throw StateError('fixture malformed')
              : XbSuccess(_records(count)),
        );
        await _setup(tester, service, brand);
        expect(find.text(statusBalance), findsOneWidget);
        expect(find.text(statusCount), findsOneWidget);
        if (count == 0 || count == null) {
          expect(find.text('重新检测'), findsOneWidget);
          expect(find.text('0 次 · 未达标'), findsNothing);
        }
        if (count == 9 && balance == 200) {
          final label = tester.getCenter(find.text('成功邀请 ≥10 次'));
          final status = tester.getCenter(find.text(statusCount));
          expect(status.dx, greaterThan(label.dx));
          expect(status.dy, closeTo(label.dy, 1));
          expect(find.descendant(of: _dialog, matching: find.byIcon(Icons.cancel)), findsOneWidget);
        }
        expect(tester.widget<FilledButton>(_continue).onPressed != null, pass);
        expect(_submit, findsNothing);
        expect(tester.getSize(_continue).width, closeTo(tester.getSize(find.widgetWithText(FilledButton, '关闭')).width, 0.1));
        verify(() => service.getInviteInfo()).called(1);
        verify(() => service.getCommissionRecords(page: 1, pageSize: 10)).called(1);
        verifyNever(() => service.getWithdrawMethods());
        verifyNever(
          () => service.withdrawCommission(
            method: any(named: 'method'),
            account: any(named: 'account'),
          ),
        );
      });
    }
  }

  for (final scenario in ['close', 'switch account', 'background']) {
    testWidgets('pending withdrawal checks: $scenario', (
      tester,
    ) async {
      final service = _Service();
      final lateRecords = Completer<XbResult<List<XbCommissionRecord>>>();
      when(() => service.getInviteInfo()).thenAnswer(
        (_) async => XbSuccess(_invite(200)),
      );
      when(
        () => service.getCommissionRecords(page: 1, pageSize: 10),
      ).thenAnswer((_) => lateRecords.future);
      final container = await _setup(tester, service, 'brand_a');
      expect(find.text('已达标'), findsOneWidget);
      expect(find.text('检测中…'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '正在核对提现条件…')).onPressed, isNull);
      if (scenario == 'close') {
        await tester.tap(find.text('关闭'));
      } else if (scenario == 'switch account') {
        (container.read(authStateProvider.notifier) as _Auth).switchAccount();
      } else {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
      }
      lateRecords.complete(XbSuccess(_records(10)));
      if (scenario == 'background') {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      await tester.pumpAndSettle();
      if (scenario == 'background') {
        expect(find.text('至少 10 次 · 已达标'), findsOneWidget);
        expect(tester.widget<FilledButton>(_continue).onPressed, isNotNull);
      } else if (scenario == 'close') {
        expect(_dialog, findsNothing);
      } else {
        expect(find.textContaining('账号状态已变化'), findsOneWidget);
      }
      if (scenario != 'background') {
        expect(_continue, findsNothing);
        expect(find.text('至少 10 次 · 已达标'), findsNothing);
      }
      expect(_submit, findsNothing);
      verifyNever(() => service.getWithdrawMethods());
      expect(tester.takeException(), isNull);
    });
  }

  for (final outcome in ['success', 'success while covered', 'unknown', 'switch account', 'methods fail']) {
    testWidgets('withdrawal needs real details and submits once: $outcome', (
      tester,
    ) async {
      final service = _Service();
      final response = Completer<XbResult<bool>>();
      when(() => service.getInviteInfo()).thenAnswer(
        (_) async => XbSuccess(_invite(200)),
      );
      when(
        () => service.getCommissionRecords(page: 1, pageSize: 10),
      ).thenAnswer((_) async => XbSuccess(_records(10)));
      when(() => service.getWithdrawMethods()).thenAnswer(
        (_) async => outcome == 'methods fail'
            ? const XbFailure(
                XbNetwork(XbNetworkKind.timeout, 'fixture timeout'),
              )
            : const XbSuccess(['USDT-TRC20']),
      );
      when(
        () => service.withdrawCommission(
          method: 'USDT-TRC20',
          account: 'fixture-account',
        ),
      ).thenAnswer((_) => response.future);
      final container = await _setup(tester, service, 'brand_b');
      await tester.tap(_continue);
      await tester.pumpAndSettle();
      final amountLabel = find.text('整笔提现额');
      final amountValue = find.descendant(of: _dialog, matching: find.text('¥200.00'));
      expect(tester.getCenter(amountValue).dx, greaterThan(tester.getCenter(amountLabel).dx));
      expect(tester.getTopLeft(amountLabel).dy, greaterThan(
        tester.getTopLeft(find.textContaining('提交不代表已打款')).dy,
      ));
      expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
      if (outcome == 'methods fail') {
        expect(find.textContaining('无法核实可用收款方式'), findsOneWidget);
        verifyNever(
          () => service.withdrawCommission(
            method: any(named: 'method'),
            account: any(named: 'account'),
          ),
        );
        return;
      }

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USDT-TRC20').last);
      await tester.pumpAndSettle();
      final account = find.byType(TextField);
      final confirm = find.text('确认收款方式和账户真实、准确');
      await tester.enterText(account, ' wrong-account ');
      await tester.pump();
      expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(_submit).onPressed, isNotNull);
      await tester.enterText(account, ' fixture-account ');
      await tester.pump();
      expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      final callback = tester.widget<FilledButton>(_submit).onPressed!;
      callback();
      callback();
      await tester.pump();
      if (outcome == 'success') {
        await tester.tapAt(const Offset(20, 500));
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(_dialog, findsOneWidget);
      }
      if (outcome == 'switch account') {
        (container.read(authStateProvider.notifier) as _Auth).switchAccount();
      }
      if (outcome == 'success while covered') {
        unawaited(showDialog<void>(context: tester.element(_dialog), builder: (_) => const AlertDialog(title: Text('覆盖层'))));
        await tester.pumpAndSettle();
      }
      response.complete(XbSuccess(outcome != 'unknown'));
      await tester.pumpAndSettle();
      verify(
        () => service.withdrawCommission(
          method: 'USDT-TRC20',
          account: 'fixture-account',
        ),
      ).called(1);
      if (outcome == 'success') {
        expect(_dialog, findsNothing);
        expect(find.textContaining('请等待人工审核'), findsOneWidget);
      } else if (outcome == 'success while covered') {
        expect(find.text('覆盖层'), findsOneWidget);
        expect(find.byType(WithdrawCommissionDialog, skipOffstage: false), findsNothing);
        await tester.pump(const Duration(seconds: 3));
      } else if (outcome == 'switch account') {
        expect(find.textContaining('账号状态已变化'), findsOneWidget);
        expect(find.textContaining('请等待人工审核'), findsNothing);
      } else {
        expect(find.textContaining('申请结果尚未确认'), findsOneWidget);
        expect(_submit, findsNothing);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('佣金提现'));
        await tester.pumpAndSettle();
        expect(find.textContaining('申请结果尚未确认'), findsOneWidget);
        expect(_continue, findsNothing);
        container.read(networkRecoveryProvider.notifier).publish();
        await tester.pumpAndSettle();
        verifyNever(() => service.withdrawCommission(method: any(named: 'method'), account: any(named: 'account')));
      }
      expect(tester.takeException(), isNull);
      if (outcome == 'success') await tester.pump(const Duration(seconds: 3));
    });
  }
}
