/// 应用版本信息（形态 A「关于」条目展示，便于确认安装的是否最新构建）。
///
/// - 版本号 / buildNumber：来自 `package_info_plus`（读 pubspec version: x.y.z+build）。
/// - 构建标识 [kBuildTag]：编译期 `--dart-define=XB_BUILD_TAG=...` 注入（通常为构建时间戳）。
///   未注入时为空 —— 这样每次重新构建只要带上 tag，App 里就能一眼看出是不是新包。
library;

import 'package:package_info_plus/package_info_plus.dart';

/// 编译期注入的构建标识（构建脚本传 `--dart-define=XB_BUILD_TAG=20260607-0530`）。
const String kBuildTag = String.fromEnvironment('XB_BUILD_TAG');

/// 取展示用版本串：`v{version}-{buildTag}`（如 `v0.0.1-202606071230`），简洁有意义。
/// buildTag = 构建时间戳（`--dart-define=XB_BUILD_TAG`）；version 来自 `--build-name`。
/// versionCode（buildNumber，Android 升级判定用）不在此展示，仅内部维护。
Future<String> loadVersionLabel() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return kBuildTag.isEmpty ? 'v${info.version}' : 'v${info.version}-$kBuildTag';
  } catch (_) {
    // package_info 不可用（极少见）→ 至少给出构建 tag。
    return kBuildTag.isEmpty ? 'v—' : kBuildTag;
  }
}
