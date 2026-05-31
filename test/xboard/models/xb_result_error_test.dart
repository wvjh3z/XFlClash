/// W2.3.7 + W2.7.5 — XbDomainError 7 子类 + XbResult sealed 单测。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show BusinessErrorKind, NetworkErrorKind, RateLimitKind;

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';

void main() {
  group('XbDomainError 7 子类', () {
    test('7 子类构造 + message 透传', () {
      expect(const XbUnauthorized('未登录').message, '未登录');
      expect(
        const XbRateLimit(RateLimitKind.login, 5, '太频繁').retryAfterMinutes,
        5,
      );
      expect(
        const XbBusiness(BusinessErrorKind.banned, '封禁', null).kind,
        BusinessErrorKind.banned,
      );
      expect(
        const XbNetwork(NetworkErrorKind.timeout, '超时').kind,
        NetworkErrorKind.timeout,
      );
      expect(const XbServer(503, '服务异常').httpStatusCode, 503);
      expect(const XbSecurity('TLS 失败').message, 'TLS 失败');
      expect(const XbUnexpected('getOrders', '出错').operation, 'getOrders');
    });

    test('redirecting factory 等价于直接构造', () {
      expect(XbDomainError.unauthorized('x'), isA<XbUnauthorized>());
      expect(
        XbDomainError.business(BusinessErrorKind.generic, 'x', null),
        isA<XbBusiness>(),
      );
      expect(XbDomainError.server(500, 'x'), isA<XbServer>());
    });

    test('sealed switch 编译期穷举 7 子类', () {
      String label(XbDomainError e) => switch (e) {
            XbUnauthorized() => 'unauthorized',
            XbRateLimit() => 'rateLimit',
            XbBusiness() => 'business',
            XbNetwork() => 'network',
            XbServer() => 'server',
            XbSecurity() => 'security',
            XbUnexpected() => 'unexpected',
          };
      expect(label(const XbUnauthorized('m')), 'unauthorized');
      expect(label(const XbSecurity('m')), 'security');
    });

    test('XbBusiness 不暴露 httpStatusCode（C37）—— 类型无该字段', () {
      const b = XbBusiness(BusinessErrorKind.banned, 'm', {'email': ['x']});
      expect(b.validationErrors, {'email': ['x']});
      // 编译期保证：XbBusiness 无 httpStatusCode getter（C37）。
    });
  });

  group('XbResult sealed', () {
    test('XbSuccess / XbFailure 构造 + 命名（非 Ok/Err）', () {
      const ok = XbSuccess<int>(42);
      const err = XbFailure<int>(XbUnauthorized('未登录'));
      expect(ok.data, 42);
      expect((err.error as XbUnauthorized).message, '未登录');
    });

    test('when() 强制处理两分支', () {
      const XbResult<int> ok = XbSuccess(7);
      const XbResult<int> err = XbFailure(XbServer(500, 'boom'));
      expect(ok.when(success: (d) => 'ok:$d', failure: (_) => 'fail'), 'ok:7');
      expect(err.when(success: (_) => 'ok', failure: (e) => 'fail:${e.message}'),
          'fail:boom');
    });

    test('isSuccess / dataOrNull / errorOrNull', () {
      const XbResult<String> ok = XbSuccess('hi');
      const XbResult<String> err = XbFailure(XbSecurity('tls'));
      expect(ok.isSuccess, isTrue);
      expect(ok.dataOrNull, 'hi');
      expect(ok.errorOrNull, isNull);
      expect(err.isSuccess, isFalse);
      expect(err.dataOrNull, isNull);
      expect(err.errorOrNull, isA<XbSecurity>());
    });

    test('factory success/failure 等价', () {
      expect(XbResult<int>.success(1), isA<XbSuccess<int>>());
      expect(
        XbResult<int>.failure(const XbUnauthorized('x')),
        isA<XbFailure<int>>(),
      );
    });
  });
}
