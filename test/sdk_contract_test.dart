/// W9.1 — SDK 公共表面契约测试（DD-20 / 决策 #1）。
///
/// 断言 SDK barrel 暴露的公共表面**形状不变**：枚举数量 / sealed 子类 / 双重判定子串。
/// 任一仓改 SDK 公共表面 → 本测试 fail → 触发 design 复扫（决策 #1）。
/// **跨仓共享**（ξ-DD-20）：客户端 + SDK 双仓 CI 都应跑等价断言。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';

void main() {
  group('SDK 枚举数量契约（DD-20）', () {
    test('BusinessErrorKind = 22 子类', () {
      expect(BusinessErrorKind.values.length, 22);
    });
    test('RateLimitKind = 4', () {
      expect(RateLimitKind.values.length, 4);
    });
    test('NetworkErrorKind = 5', () {
      expect(NetworkErrorKind.values.length, 5);
    });
    test('OrderStatus = 5（pending/processing/cancelled/completed/discounted）', () {
      expect(OrderStatus.values.length, 5);
      expect(OrderStatus.values.map((e) => e.name), [
        'pending', 'processing', 'cancelled', 'completed', 'discounted',
      ]);
    });
    test('PlanPeriod = 8（旧版 *_price 命名）', () {
      expect(PlanPeriod.values.length, 8);
      expect(PlanPeriod.monthly.value, 'month_price');
      expect(PlanPeriod.resetTraffic.value, 'reset_price');
    });
  });

  group('SdkResult sealed 双分支（Success/Failure 非 Ok/Err，F410）', () {
    test('Success 解构', () {
      const SdkResult<int> r = Success(42);
      final v = switch (r) {
        Success(:final data) => data,
        Failure() => -1,
      };
      expect(v, 42);
    });
    test('Failure 解构', () {
      const SdkResult<int> r = Failure(UnauthorizedError('x'));
      final isFail = switch (r) {
        Success() => false,
        Failure() => true,
      };
      expect(isFail, isTrue);
    });
  });

  group('SdkError sealed 7 子类（R6.A）', () {
    test('7 子类可构造 + switch 穷举', () {
      final errors = <SdkError>[
        const UnauthorizedError('a'),
        const RateLimitError('b', kind: RateLimitKind.login),
        const BusinessError('c', httpStatusCode: 400),
        const NetworkError('d', kind: NetworkErrorKind.timeout),
        const ServerError('e', httpStatusCode: 500),
        const SecurityError('f'),
        UnexpectedError('g', cause: 'x', stackTrace: StackTrace.empty, operation: 'op'),
      ];
      for (final e in errors) {
        final label = switch (e) {
          UnauthorizedError() => 'unauth',
          RateLimitError() => 'rate',
          BusinessError() => 'business',
          NetworkError() => 'network',
          ServerError() => 'server',
          SecurityError() => 'security',
          UnexpectedError() => 'unexpected',
        };
        expect(label, isNotEmpty);
      }
      expect(errors, hasLength(7));
    });
  });

  group('CheckoutOutcome sealed 5 final class（F346）', () {
    test('5 分支 switch 穷举', () {
      final outcomes = <CheckoutOutcome>[
        const CheckoutRedirect(url: 'u'),
        const CheckoutQrCode(qrCodeUrl: 'q'),
        const CheckoutPaid(),
        const CheckoutCanceled(),
        const CheckoutFailed(message: 'm'),
      ];
      for (final o in outcomes) {
        final label = switch (o) {
          CheckoutRedirect() => 'redirect',
          CheckoutQrCode() => 'qr',
          CheckoutPaid() => 'paid',
          CheckoutCanceled() => 'canceled',
          CheckoutFailed() => 'failed',
        };
        expect(label, isNotEmpty);
      }
      expect(outcomes, hasLength(5));
    });
  });
}
