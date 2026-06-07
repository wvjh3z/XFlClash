/// 应用版本信息（形态 A「我的」Tab「关于」条目展示）。
///
/// **两套版本号，不同来源（用户决策）**：
/// - 设置 → 关于（FlClash 原生 AboutView）：显示**底座版本**（`packageInfo.version` = build-name
///   = FlClash 0.8.93），沿用上游不动。
/// - 我的 Tab → 关于（本函数）：显示 **MyClient 自有产品版本 + 构建时间戳**，即 `v0.0.1-{tag}`。
///   产品版本与底座脱钩，不走 packageInfo（那是底座版本），改由编译期 `--dart-define` 注入。
library;

/// 编译期注入的 MyClient 产品版本（构建脚本传 `--dart-define=XB_PRODUCT_VERSION=0.0.1`，
/// 取自 `flavors/brand_a/flavor.yaml` 的 versionName）。未注入时回退 0.0.0。
const String kProductVersion =
    String.fromEnvironment('XB_PRODUCT_VERSION', defaultValue: '0.0.0');

/// 编译期注入的构建标识（构建脚本传 `--dart-define=XB_BUILD_TAG=202606071230`，构建时间戳）。
const String kBuildTag = String.fromEnvironment('XB_BUILD_TAG');

/// 取展示用版本串：`v{产品版本}-{buildTag}`（如 `v0.0.1-202606072036`）。
/// buildTag 为空（未注入）时退化为 `v{产品版本}`。同步函数（编译期常量，无需异步）。
String myClientVersionLabel() =>
    kBuildTag.isEmpty ? 'v$kProductVersion' : 'v$kProductVersion-$kBuildTag';
