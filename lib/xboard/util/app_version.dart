/// 应用版本信息（形态 A「关于」条目展示）。
///
/// 沿用 FlClash 底座版本号（`package_info_plus` → pubspec version），不另起自有版本号 /
/// 构建标识。`PackageInfo.fromPlatform()` 与 FlClash 原生关于页用的 `globalState.packageInfo`
/// 同源，但带 try/catch 兜底（widget 测试无 plugin 时不抛），故各「关于」入口统一用本函数。
library;

import 'package:package_info_plus/package_info_plus.dart';

/// 取展示用版本串（沿用 FlClash 版本号，如 `0.8.93`）。plugin 不可用时回退占位。
Future<String> loadVersionLabel() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  } catch (_) {
    return '—';
  }
}
