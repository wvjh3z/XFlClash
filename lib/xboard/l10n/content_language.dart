/// Content-Language 后端 locale 映射（W3.10 / F398 / F399 / DD-4）。
///
/// **背景**：SDK 不主动发 `Content-Language` header（F399）；后端 `Language` middleware
/// 直接 `App::setLocale(header)` **无白名单**（F398），影响后端返回 message 的语言
/// （SDK 异常映射子串判定已支持中英双语 F385）。反腐层在 bootstrap 注入**一次性默认 header**
/// （DD-4，非 per-call）。
///
/// **后端支持 4 locale**：`en-US` / `ru-RU` / `zh-CN` / `zh-TW`；v0.1 客户端 UI 仅 3 语
/// （en/ru/zh_CN，D15 简体），故 zh-Hant-* → `zh-CN`（v0.1 不发 zh-TW）、ja/其他 → `en-US`
/// （与 §E i18n fallback：ja/其他 → en 一致）。
library;

/// 把 Flutter 系统 locale（如 `zh`, `zh_Hant_TW`, `ru`, `ja`, `en_US`）映射到后端
/// `Content-Language` header 值（`zh-CN` / `ru-RU` / `en-US`）。
///
/// 规则（D15 / §E i18n fallback）：
/// - `zh*`（含 zh-Hans / zh-Hant / zh-TW）→ `zh-CN`（v0.1 统一简体，不发 zh-TW）
/// - `ru*` → `ru-RU`
/// - 其他（含 `ja` / `en` / 未知）→ `en-US`
String mapToBackendLocale(String languageTag) {
  // 归一：取主语言子标签（'zh_Hant_TW' / 'zh-Hant-TW' → 'zh'）。
  final primary = languageTag.replaceAll('_', '-').split('-').first.toLowerCase();
  return switch (primary) {
    'zh' => 'zh-CN',
    'ru' => 'ru-RU',
    _ => 'en-US',
  };
}

/// 后端 `Content-Language` header 名（HTTP 标准头）。
const String kContentLanguageHeader = 'Content-Language';
