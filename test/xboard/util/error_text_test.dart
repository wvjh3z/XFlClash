/// 统一错误文案解析 resolveErrorText 单测（触类旁通：后端 message 透传规则）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show BusinessErrorKind, NetworkErrorKind, RateLimitKind;

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/util/error_text.dart';

void main() {
  group('resolveErrorText', () {
    test('business.generic 有后端 message → 透传', () {
      final t = resolveErrorText(
          const XbBusiness(BusinessErrorKind.generic, '邮箱或密码错误', null));
      expect(t, '邮箱或密码错误');
    });

    test('business.generic 空 message → 兜底本地化', () {
      final t = resolveErrorText(
          const XbBusiness(BusinessErrorKind.generic, '', null));
      expect(t, '操作失败，请稍后重试');
    });

    test('business.validationFailed 有 message → 透传', () {
      final t = resolveErrorText(
          const XbBusiness(BusinessErrorKind.validationFailed, '邮箱格式不正确', null));
      expect(t, '邮箱格式不正确');
    });

    test('business.banned → 始终用客户端本地化（不受后端文案波动影响）', () {
      final t = resolveErrorText(
          const XbBusiness(BusinessErrorKind.banned, 'raw backend', null));
      expect(t, contains('封禁'));
    });

    test('server 有 message → 透传', () {
      final t = resolveErrorText(const XbServer(503, '后端维护中'));
      expect(t, '后端维护中');
    });

    test('server 空 message → 兜底', () {
      final t = resolveErrorText(const XbServer(500, ''));
      expect(t, '服务异常，请稍后重试');
    });

    test('unexpected 有 message → 透传', () {
      final t = resolveErrorText(const XbUnexpected('login', 'TypeError xyz'));
      expect(t, 'TypeError xyz');
    });

    test('unexpected 空 message → 用传入 fallback', () {
      final t = resolveErrorText(const XbUnexpected('login', ''),
          fallback: '登录失败，请稍后重试');
      expect(t, '登录失败，请稍后重试');
    });

    test('unauthorized → 固定文案（不泄漏后端原文）', () {
      final t = resolveErrorText(const XbUnauthorized('token gone'));
      expect(t, '登录已过期，请重新登录');
    });

    test('security → 固定文案', () {
      final t = resolveErrorText(const XbSecurity('cert pinning failed'));
      expect(t, '安全连接失败');
    });

    test('network → 固定文案', () {
      final t = resolveErrorText(
          const XbNetwork(NetworkErrorKind.timeout, 'connection timed out'));
      expect(t, '网络异常，请检查网络后重试');
    });

    test('rateLimit 有分钟 → 倒计时文案', () {
      final t = resolveErrorText(
          const XbRateLimit(RateLimitKind.login, 5, 'too many'));
      expect(t, contains('5 分钟'));
    });
  });

  group('errorAllowsRetry', () {
    test('网络/服务端/未预期 → 可重试', () {
      expect(errorAllowsRetry(const XbNetwork(NetworkErrorKind.unknown, '')), isTrue);
      expect(errorAllowsRetry(const XbServer(500, '')), isTrue);
      expect(errorAllowsRetry(const XbUnexpected('op', '')), isTrue);
    });

    test('业务/限流/未认证/安全 → 不可重试', () {
      expect(
          errorAllowsRetry(const XbBusiness(BusinessErrorKind.generic, '', null)),
          isFalse);
      expect(errorAllowsRetry(const XbRateLimit(RateLimitKind.login, 1, '')),
          isFalse);
      expect(errorAllowsRetry(const XbUnauthorized('')), isFalse);
      expect(errorAllowsRetry(const XbSecurity('')), isFalse);
    });
  });
}
