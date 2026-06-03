/// R4.4 浏览器 User-Agent 伪装 —— 全链路统一 UA 来源（API / config / 订阅 / 未来更新）。
///
/// **目的**：把所有「管理流量」HTTP 请求的 UA 伪装成真实浏览器，混入正常 HTTPS 流量，躲 GFW
/// **浅层 UA 检测**。原 SDK 默认 UA `FlClash-XBoard-SDK/1.0`（含 flclash 特征串）一眼即翻墙客户端。
///
/// **覆盖范围**（用户 2026-06-03 决策：尽可能全伪装）：
/// - SDK API 请求（登录/套餐/订单…）：bootstrap initialize 传 [current] + allowNonFlclashUa
/// - config.json 拉取（[buildReleasedIsolatedDio]）：默认 header 注入 [current]
/// - 加密订阅拉取（同上放行 dio）：同
/// - 未来软件更新：复用同一放行 dio → 自动带 [current]
///
/// **固定不随机**（用户决策）：每平台一个固定真实浏览器 UA。随机化反因同 session UA 跳变触发
/// 风控更可疑。版本号选「较新但非最前沿」（Chrome 131 / Safari 17.6），贴合多数真实用户不立即升级。
///
/// **诚实局限（不夸大）**：UA 伪装只骗浅层 UA 字符串检测。GFW 深度检测靠 TLS 指纹（JA3/JA4）/
/// SNI / 流量时序，**非 UA 层能改**。本伪装是「第一层」，须配合 R4.9 海外 CDN（Cloudflare 域前置
/// 藏 SNI）才有纵深意义，单独扛不住深度检测。
///
/// **下发覆盖（不做）**：曾评估 config.json 下发 UA 模板（避免内置版本老化成指纹），用户决策
/// **本期不做**，留可选增强（避免再改 config.json 格式 + 运营更新文件）。
library;

import 'dart:io' show Platform;

/// 各平台固定真实浏览器 UA（R4.4）。
class XboardUserAgent {
  XboardUserAgent._();

  /// Android → Chrome on Android（Pixel）。
  static const String android =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  /// iOS → Safari on iPhone。
  static const String ios =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1';

  /// Windows → Chrome on Windows。
  static const String windows =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// macOS → Safari on macOS。
  static const String macos =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/17.6 Safari/605.1.15';

  /// Linux → Chrome on Linux。
  static const String linux =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// 兜底（未知平台 / 测试）→ Windows Chrome（最通用）。
  static const String fallback = windows;

  /// 当前运行平台对应的浏览器 UA（按 [Platform] 分发；测试可用 [forPlatform] 注入）。
  static String get current {
    if (Platform.isAndroid) return android;
    if (Platform.isIOS) return ios;
    if (Platform.isWindows) return windows;
    if (Platform.isMacOS) return macos;
    if (Platform.isLinux) return linux;
    return fallback;
  }

  /// 按平台名取 UA（纯函数，便于单测穷举；platform ∈ android/ios/windows/macos/linux）。
  static String forPlatform(String platform) => switch (platform.toLowerCase()) {
        'android' => android,
        'ios' => ios,
        'windows' => windows,
        'macos' => macos,
        'linux' => linux,
        _ => fallback,
      };
}
