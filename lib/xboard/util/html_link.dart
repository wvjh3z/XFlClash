/// 后端富文本 HTML 链接统一解析 / 打开（框架，conventions §11 系统化修复）。
///
/// **背景（X→Y）**：后端知识库/套餐正文里的 `<a href>` 形态多样——绝对 URL
/// （`https://...`）、**相对路径**（`downloads/x.apk`）、**根相对 / SPA 路由**（`/#/dashboard`）、
/// `mailto:` / 页内锚点（`#sec`）/ `javascript:`。flutter_html 的 `onLinkTap` 只把**原始串**
/// 交回；若调用方只认 `http/https` 绝对 URL，则**所有相对链接都不跳转**（id=22 的
/// `downloads/...apk` 即此）。
///
/// **框架**：[resolveHtmlLink] 把 (raw, base) 归一成「可打开的绝对 Uri」或 null（忽略）；
/// [openHtmlLink] 解析后用外部应用打开（永不抛）。所有 flutter_html `onLinkTap` **统一走它**，
/// 不在各页各自判断（§11：一处实现、契约明确）。
///
/// **base**：相对链接的解析基准 = 当前站点根（API endpoint，`apiEndpointProvider`）。
/// 知识库正文在 Xboard 面板内编写，相对资源（下载/路由）相对面板站点根。
library;

import 'package:url_launcher/url_launcher.dart';

/// 把原始 href 归一成「可外部打开的绝对 Uri」；不可打开 / 应忽略 → null（纯函数，可单测）。
///
/// 规则：
/// - 空 / 纯页内锚点（`#` / `#sec`）/ `javascript:` / `about:blank` → null（不跳转）。
/// - 绝对 `http`/`https`/`mailto`/`tel` → 原样返回；其它 scheme（如 `data:`）→ null。
/// - **相对**（`downloads/x.apk` / `/path` / `/#/route`）→ 用 [base] 解析成绝对 http(s)；
///   [base] 缺失 / 非 http(s) → null（无从解析）。
Uri? resolveHtmlLink(String? raw, {String? base}) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();
  if (s == '#' || s.startsWith('#')) return null; // 页内锚点：无 in-app 语义
  if (lower.startsWith('javascript:') || lower == 'about:blank') return null;

  final uri = Uri.tryParse(s);
  if (uri == null) return null;

  if (uri.hasScheme) {
    if (uri.isScheme('http') ||
        uri.isScheme('https') ||
        uri.isScheme('mailto') ||
        uri.isScheme('tel')) {
      return uri;
    }
    return null; // 其它 scheme 不处理
  }

  // 相对链接 → 需 base 解析。
  if (base == null) return null;
  final b = Uri.tryParse(base.trim());
  if (b == null || !(b.isScheme('http') || b.isScheme('https'))) return null;
  final resolved = b.resolveUri(uri);
  return (resolved.isScheme('http') || resolved.isScheme('https'))
      ? resolved
      : null;
}

/// 解析并用外部应用打开链接（永不抛）。供 flutter_html `onLinkTap` 统一调用。
Future<void> openHtmlLink(String? raw, {String? base}) async {
  final uri = resolveHtmlLink(raw, base: base);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // 无可用 handler / 平台限制 → 静默（不崩、不打扰）。
  }
}
