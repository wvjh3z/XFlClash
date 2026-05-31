/// W2.5.5 — BusinessErrorKind 22 子类 i18n 三语全覆盖 + arb 对齐校验。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' show BusinessErrorKind;

import 'package:fl_clash/xboard/l10n/xboard_business_messages.dart';

void main() {
  group('运行期 map 三语全覆盖（β-8）', () {
    for (final locale in XbLocale.values) {
      test('$locale：22 子类全有文案 + 非空', () {
        for (final kind in BusinessErrorKind.values) {
          final msg = localizedBusinessMessage(kind, locale);
          expect(msg, isNotEmpty, reason: '$kind @ $locale 文案为空');
        }
      });
    }

    test('BusinessErrorKind 恰好 22 子类（新增触发 design 复扫）', () {
      expect(BusinessErrorKind.values, hasLength(22));
    });
  });

  group('resolveXbLocale / businessErrorKey', () {
    test('locale 映射（ja/其他 → en 兜底，DD-16）', () {
      expect(resolveXbLocale('zh'), XbLocale.zhCN);
      expect(resolveXbLocale('ru'), XbLocale.ru);
      expect(resolveXbLocale('en'), XbLocale.en);
      expect(resolveXbLocale('ja'), XbLocale.en);
      expect(resolveXbLocale('fr'), XbLocale.en);
    });

    test('key 规约 xb_business_<enumName>', () {
      expect(businessErrorKey(BusinessErrorKind.banned), 'xb_business_banned');
      expect(businessErrorKey(BusinessErrorKind.validationFailed),
          'xb_business_validationFailed');
    });
  });

  group('arb 文件与 22 子类对齐（SSoT 一致）', () {
    const arbDir = 'lib/xboard/l10n';
    for (final arb in ['xboard_zh_CN.arb', 'xboard_en.arb', 'xboard_ru.arb']) {
      test('$arb 含全部 22 个 xb_business_* key', () {
        final json = jsonDecode(File('$arbDir/$arb').readAsStringSync())
            as Map<String, dynamic>;
        for (final kind in BusinessErrorKind.values) {
          final key = businessErrorKey(kind);
          expect(json.containsKey(key), isTrue, reason: '$arb 缺 $key');
          expect((json[key] as String).trim(), isNotEmpty);
        }
      });
    }
  });
}
