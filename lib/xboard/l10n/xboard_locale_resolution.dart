/// Xboard i18n locale 解析（合规 § E / ι-2 / DD-16）。
///
/// **三层独立 locale（DD-16）**：FlClash 底座 4 语 / Xboard 模块 3 语（zh/en/ru）/ 后端
/// Content-Language。本文件管「Xboard UI 该用哪个 locale 渲染」。
///
/// **fallback（§ E / ι-2）**：zh* → zh-CN（v0.1 简体，繁体也归简）；ru* → ru-RU；
/// 其他（ja/fr/es/未知）→ en（**不** fallback 中文避免混合显示）。与 `content_language.dart`
/// 的 `mapToBackendLocale` 同源映射（W8.8 一致性）。
library;

import 'dart:ui' show Locale;

/// Xboard 模块支持的 3 个 locale（D15 v0.1）。
const List<Locale> kXboardSupportedLocales = [
  Locale('zh', 'CN'),
  Locale('en', 'US'),
  Locale('ru', 'RU'),
];

/// MaterialApp.localeResolutionCallback 实现：把系统 locale 解析为 Xboard 支持的 3 语之一。
///
/// [device] 系统首选 locale；[supported] 一般传 [kXboardSupportedLocales]。
Locale resolveXboardLocale(Locale? device, Iterable<Locale> supported) {
  if (device == null) return const Locale('en', 'US');
  switch (device.languageCode.toLowerCase()) {
    case 'zh':
      return const Locale('zh', 'CN'); // 简繁都归简（v0.1，D15）
    case 'ru':
      return const Locale('ru', 'RU');
    default:
      return const Locale('en', 'US'); // ja/fr/es/未知 → en（不 fallback 中文）
  }
}

/// arb miss key fallback 链：当前 locale → en → key 名。
///
/// [lookup] 给定 (locale, key) 返回文案或 null（miss）。debug 下 miss 返回带标记的 key 名
/// （红字 banner 提示），release 返 key 名（静默）。
String resolveArbValue(
  String key,
  String currentLocale,
  String? Function(String locale, String key) lookup, {
  bool debug = false,
}) {
  final cur = lookup(currentLocale, key);
  if (cur != null) return cur;
  final en = lookup('en', key);
  if (en != null) return en;
  return debug ? '⚠$key' : key;
}
