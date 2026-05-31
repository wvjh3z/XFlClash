/// W2.6.6 — validationFailed 字段级渲染 sanitize 逻辑单测（β-8 + θ-9）。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/widgets/xb_validation_error_renderer.dart';

void main() {
  group('sanitizeValidationErrors（θ-9）', () {
    test('5 个白名单字段正常渲染（取首条）', () {
      final out = sanitizeValidationErrors({
        'email': ['Email already taken', 'second ignored'],
        'password': ['min:8'],
        'inviteCode': ['invalid'],
        'emailVerifyCode': ['expired'],
        'couponCode': ['not found'],
      });
      expect(out['email'], 'Email already taken'); // 取首条
      expect(out['password'], 'min:8');
      expect(out.length, 5);
    });

    test('白名单外字段被丢弃（θ-9 防注入撑爆）', () {
      final out = sanitizeValidationErrors({
        'email': ['ok'],
        'evil_field': ['x' * 50],
        '__proto__': ['attack'],
      });
      expect(out.containsKey('email'), isTrue);
      expect(out.containsKey('evil_field'), isFalse);
      expect(out.containsKey('__proto__'), isFalse);
    });

    test('超长 message 截断到 200 字符（θ-9 性能防护）', () {
      final out = sanitizeValidationErrors({
        'email': ['e' * 500],
      });
      expect(out['email']!.length, kXbValidationMessageMaxLen);
    });

    test('空 list / 全空白 message 跳过', () {
      final out = sanitizeValidationErrors({
        'email': [],
        'password': ['   ', ''],
        'couponCode': ['  real  '],
      });
      expect(out.containsKey('email'), isFalse);
      expect(out.containsKey('password'), isFalse);
      expect(out['couponCode'], '  real  '); // 非空白保留（不 trim 内容）
    });

    test('null → 空 map', () {
      expect(sanitizeValidationErrors(null), isEmpty);
    });

    test('保持插入顺序（首个出错字段 = first key）', () {
      final out = sanitizeValidationErrors({
        'password': ['p'],
        'email': ['e'],
      });
      expect(out.keys.first, 'password');
    });
  });

  group('scrollToFirstError', () {
    testWidgets('滚到首个出错字段（有 context 不抛）', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 2000),
                SizedBox(key: key, height: 50),
              ],
            ),
          ),
        ),
      );
      // 不抛即通过（ensureVisible 对真实 context 生效）
      expect(
        () => scrollToFirstError({'email': 'err'}, {'email': key}),
        returnsNormally,
      );
    });

    testWidgets('空 errors / 无匹配 key → no-op 不抛', (tester) async {
      await tester.pumpWidget(const SizedBox());
      expect(() => scrollToFirstError({}, {}), returnsNormally);
      expect(
        () => scrollToFirstError({'email': 'e'}, {}),
        returnsNormally,
      );
    });
  });
}
