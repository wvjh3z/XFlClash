import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_types.dart';
import 'package:fl_clash/xboard/models/checkout_outcome_ui.dart';
import 'package:fl_clash/xboard/util/error_text.dart';
import '../../_fixtures/fake_xboard_sdk.dart';

void main() {
  late FakeXBoardSDK instance;
  late FakeSubApis apis;
  late XboardServiceImpl service;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    instance = FakeXBoardSDK();
    apis = instance.setupFor(XbScenario.loggedIn);
    service = XboardServiceImpl(sdk: instance);
  });
  for (final status in [0, 1, 2, 3, 4]) {
    for (final operation in ['checkout', 'cancel']) {
      test(
        '$operation reconciles exact order status $status without replay',
        () async {
          when(
            () => apis.orderApi.checkoutOrder('T', 'pay'),
          ).thenThrow(sdk.EndpointException('gateway', 405));
          when(
            () => apis.orderApi.cancelOrder('T'),
          ).thenThrow(sdk.NetworkException('lost response'));
          when(() => apis.orderApi.getOrder('T')).thenAnswer(
            (_) async => sdk.OrderModel(tradeNo: 'T', status: status),
          );
          final result = operation == 'checkout'
              ? await service.checkout('T', 'pay')
              : await service.cancelOrder('T');
          final confirmed = operation == 'checkout' ? status == 3 : status == 2;
          if (confirmed) {
            expect(result, isA<XbSuccess>());
            if (operation == 'checkout') {
              expect((result as XbSuccess).data, isA<CheckoutPaid>());
            }
          } else {
            final error = (result as XbFailure).error;
            expect(error, isA<XbUnconfirmed>());
            expect(errorAllowsRetry(error), isFalse);
            expect(resolveErrorText(error), contains('客服'));
          }
          if (operation == 'checkout') {
            verify(() => apis.orderApi.checkoutOrder('T', 'pay')).called(1);
          } else {
            verify(() => apis.orderApi.cancelOrder('T')).called(1);
          }
          verify(() => apis.orderApi.getOrder('T')).called(1);
        },
      );
    }
  }
  test(
    'unknown creation refreshes orders but does not guess a trade number',
    () async {
      when(
        () => apis.orderApi.createOrder(1, any(), couponCode: null),
      ).thenThrow(sdk.EndpointException('gateway', 503));
      when(
        () =>
            apis.orderApi.getOrders(page: 1, pageSize: 20, forceRefresh: true),
      ).thenAnswer(
        (_) async => const sdk.PaginatedList(
          data: [sdk.OrderModel(tradeNo: 'OTHER', status: 0, planId: 1)],
          total: 1,
          page: 1,
          pageSize: 20,
        ),
      );
      final result = await service.createOrder(1, XbPlanPeriod.monthly);
      expect((result as XbFailure).error, isA<XbUnconfirmed>());
      verify(
        () =>
            apis.orderApi.getOrders(page: 1, pageSize: 20, forceRefresh: true),
      ).called(1);
      verify(
        () => apis.orderApi.createOrder(1, any(), couponCode: null),
      ).called(1);
    },
  );
  test('business rejection stays business and does not query/retry', () async {
    when(
      () => apis.orderApi.cancelOrder('T'),
    ).thenThrow(sdk.ApiException('订单不可取消', 400));
    expect(
      (await service.cancelOrder('T') as XbFailure).error,
      isA<XbBusiness>(),
    );
    verifyNever(() => apis.orderApi.getOrder(any()));
  });
  test('checkout and cancellation cannot overlap while reconciling', () async {
    final detail = Completer<sdk.OrderModel?>();
    final began = Completer<void>();
    when(
      () => apis.orderApi.checkoutOrder('T', 'pay'),
    ).thenThrow(sdk.NetworkException('lost'));
    when(() => apis.orderApi.getOrder('T')).thenAnswer((_) {
      began.complete();
      return detail.future;
    });
    final first = service.checkout('T', 'pay');
    await began.future;
    expect(
      (await service.cancelOrder('T') as XbFailure).error,
      isA<XbBusiness>(),
    );
    verifyNever(() => apis.orderApi.cancelOrder(any()));
    detail.complete(const sdk.OrderModel(tradeNo: 'T', status: 3));
    expect(await first, isA<XbSuccess>());
  });
  test(
    'account switch during reconciliation cannot report old success',
    () async {
      final detail = Completer<sdk.OrderModel?>();
      final began = Completer<void>();
      when(
        () => apis.orderApi.cancelOrder('T'),
      ).thenThrow(sdk.NetworkException('lost'));
      when(() => apis.orderApi.getOrder('T')).thenAnswer((_) {
        began.complete();
        return detail.future;
      });
      final pending = service.cancelOrder('T');
      await began.future;
      when(() => instance.authSession).thenReturn(
        const sdk.AuthSessionSnapshot(
          revision: 2,
          state: sdk.AuthState.authenticated,
        ),
      );
      detail.complete(const sdk.OrderModel(tradeNo: 'T', status: 2));
      expect(
        (await pending as XbFailure).error,
        isA<XbNetwork>().having(
          (e) => e.kind,
          'kind',
          sdk.NetworkErrorKind.cancelled,
        ),
      );
    },
  );
  test('wrong order response never confirms payment', () async {
    when(
      () => apis.orderApi.checkoutOrder('T', 'pay'),
    ).thenThrow(sdk.NetworkException('lost'));
    when(() => apis.orderApi.getOrder('T')).thenAnswer(
      (_) async => const sdk.OrderModel(tradeNo: 'OTHER', status: 3),
    );
    expect(
      (await service.checkout('T', 'pay') as XbFailure).error,
      isA<XbUnconfirmed>(),
    );
  });
  test(
    'unknown invite creation is queried on later calls, never saved twice',
    () async {
      when(
        () => apis.inviteApi.generateInviteCode(),
      ).thenThrow(sdk.NetworkException('lost'));
      await service.generateInviteCode();
      await service.generateInviteCode();
      verify(() => apis.inviteApi.generateInviteCode()).called(1);
    },
  );
  test(
    'registration unknown result does not retry or pretend registered',
    () async {
      when(
        () => apis.authApi.registerResult(
          'a@b.test',
          'password',
          emailCode: null,
          inviteCode: null,
        ),
      ).thenAnswer(
        (_) async => const sdk.Failure(
          sdk.NetworkError('lost', kind: sdk.NetworkErrorKind.timeout),
        ),
      );
      final result = await service.register('a@b.test', 'password');
      expect((result as XbFailure).error, isA<XbUnconfirmed>());
      verify(
        () => apis.authApi.registerResult(
          'a@b.test',
          'password',
          emailCode: null,
          inviteCode: null,
        ),
      ).called(1);
    },
  );
  for (final status in [401, 429]) {
    test('HTTP $status never reconciles or replays a write', () async {
      when(
        () => apis.orderApi.cancelOrder('T'),
      ).thenThrow(sdk.ApiException('rejected', status));
      final result = await service.cancelOrder('T');
      expect((result as XbFailure).error, isNot(isA<XbUnconfirmed>()));
      verifyNever(() => apis.orderApi.getOrder(any()));
    });
  }
  for (final transfer in [false, true]) {
    test(
      'commission $transfer refreshes balances but never infers success',
      () async {
        when(
          () => apis.inviteApi.withdrawCommission(
            method: 'bank',
            account: 'fixture',
          ),
        ).thenThrow(sdk.NetworkException('lost'));
        when(
          () => apis.inviteApi.transferCommissionToBalance(100),
        ).thenThrow(sdk.NetworkException('lost'));
        when(() => apis.inviteApi.getInviteInfo()).thenAnswer(
          (_) async => const sdk.InviteInfoModel(codes: [], stat: []),
        );
        when(() => apis.userApi.getUserInfo()).thenAnswer(
          (_) async => const sdk.UserModel(
            email: 'fixture@example.test',
            uuid: 'fixture',
            balance: 900,
            commissionBalance: 100,
          ),
        );
        final result = transfer
            ? await service.transferCommissionToBalance(1)
            : await service.withdrawCommission(
                method: 'bank',
                account: 'fixture',
              );
        expect((result as XbFailure).error, isA<XbUnconfirmed>());
        verify(() => apis.userApi.getUserInfo()).called(1);
      },
    );
  }
  for (final active in [true, false]) {
    test('invite recovery requires a usable active code: $active', () async {
      when(
        () => apis.inviteApi.generateInviteCode(),
      ).thenThrow(sdk.NetworkException('lost'));
      when(() => apis.inviteApi.getInviteInfo()).thenAnswer(
        (_) async => sdk.InviteInfoModel(
          codes: [
            sdk.InviteCodeModel(
              userId: 1,
              code: 'fixture',
              pv: 0,
              status: !active,
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
            ),
          ],
          stat: [],
        ),
      );
      final result = await service.generateInviteCode();
      expect(
        result,
        active ? isA<XbSuccess<String>>() : isA<XbFailure<String>>(),
      );
      verify(() => apis.inviteApi.generateInviteCode()).called(1);
    });
  }
  for (final action in ['register', 'code', 'forgot', 'withdraw', 'transfer']) {
    test('legacy false is never a service write success: $action', () async {
      when(
        () => apis.authApi.registerResult(
          'fixture@example.test',
          'password',
          emailCode: null,
          inviteCode: null,
        ),
      ).thenAnswer((_) async => const sdk.Success(false));
      when(
        () => apis.authApi.sendEmailVerifyCodeResult('fixture@example.test'),
      ).thenAnswer((_) async => const sdk.Success(false));
      when(
        () => apis.authApi.forgotPassword(
          'fixture@example.test',
          '123456',
          'password',
        ),
      ).thenAnswer((_) async => false);
      when(
        () => apis.inviteApi.withdrawCommission(
          method: 'bank',
          account: 'fixture',
        ),
      ).thenAnswer((_) async => false);
      when(
        () => apis.inviteApi.transferCommissionToBalance(100),
      ).thenAnswer((_) async => false);
      final result = switch (action) {
        'register' => await service.register(
          'fixture@example.test',
          'password',
        ),
        'code' => await service.sendEmailVerifyCode('fixture@example.test'),
        'forgot' => await service.forgotPassword(
          'fixture@example.test',
          '123456',
          'password',
        ),
        'withdraw' => await service.withdrawCommission(
          method: 'bank',
          account: 'fixture',
        ),
        _ => await service.transferCommissionToBalance(1),
      };
      expect((result as XbFailure).error, isA<XbUnconfirmed>());
    });
  }
  test('invite summary never falls back to used or blank codes', () async {
    sdk.InviteCodeModel code(String value, bool used) => sdk.InviteCodeModel(
      userId: 1,
      code: value,
      pv: 0,
      status: used,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    var codes = [code('USED', true), code('  ', false)];
    when(
      () => apis.inviteApi.getInviteInfo(),
    ).thenAnswer((_) async => sdk.InviteInfoModel(codes: codes, stat: []));
    when(() => apis.userApi.getUserInfo()).thenAnswer(
      (_) async =>
          const sdk.UserModel(email: 'fixture@example.test', uuid: 'fixture'),
    );
    expect((await service.getInviteInfo()).dataOrNull?.hasCode, isFalse);
    codes = [...codes, code('UNUSED', false)];
    expect((await service.getInviteInfo()).dataOrNull?.code, 'UNUSED');
  });
}
