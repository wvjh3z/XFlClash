/// 应用版本信息（形态 A「关于」条目展示，便于确认安装的是否最新构建）。
///
/// - 版本号 / buildNumber：来自 `package_info_plus`（读 pubspec version: x.y.z+build）。
/// - 构建标识 [kBuildTag]：编译期 `--dart-define=XB_BUILD_TAG=...` 注入（通常为构建时间戳）。
///   未注入时为空 —— 这样每次重新构建只要带上 tag，App 里就能一眼看出是不是新包。
library;

import 'dart:developer' as developer;

import 'package:package_info_plus/package_info_plus.dart';

/// 编译期注入的构建标识（构建脚本传 `--dart-define=XB_BUILD_TAG=20260607-0530`）。
const String kBuildTag = String.fromEnvironment('XB_BUILD_TAG');

/// 取展示用版本串：`v{version}+{build}`，若有构建 tag 追加 ` · {tag}`。
Future<String> loadVersionLabel() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final base = 'v${info.version}+${info.buildNumber}';
    final out = kBuildTag.isEmpty ? base : '$base · $kBuildTag';
    // dart:developer.log 在 release 模式也会输出到 logcat（print 会被裁剪）。
    developer.log(out, name: 'XbVersion');
    return out;
  } catch (e) {
    developer.log('package_info failed: $e tag=$kBuildTag', name: 'XbVersion');
    // package_info 不可用（极少见）→ 至少给出构建 tag。
    return kBuildTag.isEmpty ? 'v—' : kBuildTag;
  }
}
