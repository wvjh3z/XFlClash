/// W8.7/8.8 — locale 解析 fallback + arb miss + 与 Content-Language 三层一致性。

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/l10n/content_language.dart';
import 'package:fl_clash/xboard/l10n/xboard_locale_resolution.dart';

void main() {
  group('resolveXboardLocale fallback（§E / ι-2）', () {
    test('zh* → zh-CN（简繁都归简）', () {
      expect(resolveXboardLocale(const Locale('zh'), kXboardSupportedLocales),
          const Locale('zh', 'CN'));
      expect(
          resolveXboardLocale(
              const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
              kXboardSupportedLocales),
          const Locale('zh', 'CN'));
    });
    test('ru → ru-RU', () {
      expect(resolveXboardLocale(const Locale('ru'), kXboardSupportedLocales),
          const Locale('ru', 'RU'));
    });
    test('ja/fr/未知 → en（不 fallback 中文）', () {
      expect(resolveXboardLocale(const Locale('ja'), kXboardSupportedLocales),
          const Locale('en', 'US'));
      expect(resolveXboardLocale(const Locale('fr'), kXboardSupportedLocales),
          const Locale('en', 'US'));
    });
    test('null → en', () {
      expect(resolveXboardLocale(null, kXboardSupportedLocales),
          const Locale('en', 'US'));
    });
  });

  group('resolveArbValue miss fallback 链', () {
    String? table(String locale, String key) {
      const data = {
        'zh-CN': {'hello': '你好'},
        'en': {'hello': 'Hello', 'bye': 'Bye'},
      };
      return data[locale]?[key];
    }

    test('命中当前 locale', () {
      expect(resolveArbValue('hello', 'zh-CN', table), '你好');
    });
    test('当前 miss → en 兜底', () {
      expect(resolveArbValue('bye', 'zh-CN', table), 'Bye');
    });
    test('全 miss → key 名（release）', () {
      expect(resolveArbValue('missing', 'zh-CN', table), 'missing');
    });
    test('全 miss → ⚠key（debug）', () {
      expect(resolveArbValue('missing', 'zh-CN', table, debug: true), '⚠missing');
    });
  });

  group('W8.8 三层 locale 一致性（resolveXboardLocale ↔ mapToBackendLocale）', () {
    test('zh → UI zh-CN + 后端 zh-CN', () {
      final ui = resolveXboardLocale(const Locale('zh'), kXboardSupportedLocales);
      expect('${ui.languageCode}-${ui.countryCode}', 'zh-CN');
      expect(mapToBackendLocale('zh'), 'zh-CN');
    });
    test('ru → UI ru-RU + 后端 ru-RU', () {
      final ui = resolveXboardLocale(const Locale('ru'), kXboardSupportedLocales);
      expect('${ui.languageCode}-${ui.countryCode}', 'ru-RU');
      expect(mapToBackendLocale('ru'), 'ru-RU');
    });
    test('ja → UI en-US + 后端 en-US（两层都 fallback en）', () {
      final ui = resolveXboardLocale(const Locale('ja'), kXboardSupportedLocales);
      expect('${ui.languageCode}-${ui.countryCode}', 'en-US');
      expect(mapToBackendLocale('ja'), 'en-US');
    });
  });
}
