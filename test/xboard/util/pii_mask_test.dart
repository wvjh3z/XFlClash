/// W4.4 — PII 脱敏算法（§D / ε4）。

import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/util/pii_mask.dart';

void main() {
  group('maskEmail', () {
    test('正常：前 2 + *** + 域名', () {
      expect(maskEmail('abc@example.com'), 'ab***@example.com');
    });
    test('本地部分 < 2 → ***@域名', () {
      expect(maskEmail('a@example.com'), '***@example.com');
    });
    test('格式异常（无 @）→ 保守 ***', () {
      expect(maskEmail('notanemail'), '***@***');
    });
  });

  group('maskUuid', () {
    test('正常：前 8 位 + ***', () {
      expect(maskUuid('abc12345-6789-defg'), 'abc12345***');
    });
    test('长度 < 8 → ***', () {
      expect(maskUuid('short'), '***');
    });
  });

  group('userIdHashFromToken', () {
    test('同 token → 同 hash（确定性）', () {
      expect(userIdHashFromToken('tok'), userIdHashFromToken('tok'));
    });
    test('不同 token → 不同 hash', () {
      expect(userIdHashFromToken('a'), isNot(userIdHashFromToken('b')));
    });
    test('null / 空 → anon', () {
      expect(userIdHashFromToken(null), 'anon');
      expect(userIdHashFromToken(''), 'anon');
    });
    test('length 参数控制长度', () {
      expect(userIdHashFromToken('tok', length: 16).length, 16);
    });
  });
}
