/// W3.10.4 — Content-Language 后端 locale 映射（F398 / DD-4 / §E i18n fallback）。

import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/l10n/content_language.dart';

void main() {
  group('mapToBackendLocale', () {
    test('zh* → zh-CN（含简繁，v0.1 统一简体 D15）', () {
      expect(mapToBackendLocale('zh'), 'zh-CN');
      expect(mapToBackendLocale('zh-CN'), 'zh-CN');
      expect(mapToBackendLocale('zh-Hans'), 'zh-CN');
      expect(mapToBackendLocale('zh-Hant-TW'), 'zh-CN'); // 繁体也归简体（不发 zh-TW）
      expect(mapToBackendLocale('zh_Hant_TW'), 'zh-CN'); // 下划线分隔也归一
    });

    test('ru* → ru-RU', () {
      expect(mapToBackendLocale('ru'), 'ru-RU');
      expect(mapToBackendLocale('ru-RU'), 'ru-RU');
    });

    test('ja / en / 未知 → en-US（§E fallback）', () {
      expect(mapToBackendLocale('ja'), 'en-US');
      expect(mapToBackendLocale('en'), 'en-US');
      expect(mapToBackendLocale('en-US'), 'en-US');
      expect(mapToBackendLocale('fr'), 'en-US');
      expect(mapToBackendLocale(''), 'en-US');
    });

    test('大小写不敏感', () {
      expect(mapToBackendLocale('ZH'), 'zh-CN');
      expect(mapToBackendLocale('RU-ru'), 'ru-RU');
    });
  });
}
