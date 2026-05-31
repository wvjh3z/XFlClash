/// Xboard 运行期配置接入点（design §E / NFR-2）。
///
/// **W1 占位实现**：v0.1 正式版由 `tool/prepare_flavor.dart`（W8.5）生成
/// `flavor_config.g.dart` → `XboardConfig.bind(FlavorConfig.fromGenerated())`。
/// 当前 W1 阶段用内置默认值占位，保证 bootstrap 同步阶段可编译可跑。
///
/// **铁律（NFR-2 / Property 19）**：任何「会因发行不同而变化」的值（应用名 / 包名 /
/// 品牌色 / API URL / 订阅 UA）一律走 `XboardConfig.current`，业务代码 0 处硬编码。
library;

/// flavor 配置的运行期视图（W8.5 prepare_flavor.dart 生成实体后替换占位字段）。
class XboardConfig {
  const XboardConfig({
    required this.subscribeUserAgent,
    required this.devApiEndpoint,
    required this.devSubscriptionEndpoint,
    required this.debug,
    required this.kIsTest,
  });

  /// 订阅 UA（含且仅含一个 `flclash` 子串，F202/F203）。
  final String subscribeUserAgent;

  /// W5.6 前 stub 阶段的固定出厂 API endpoint（来自 flavor.yaml bootstrapUrls.first 概念）。
  final String devApiEndpoint;

  /// W5.6 前 stub 阶段的固定出厂订阅 endpoint。
  final String devSubscriptionEndpoint;

  /// 调试模式（驱动 SDK enableLogging）。
  final bool debug;

  /// 测试环境（D63/F81：headless 无 D-Bus，强制 MemoryTokenStorage）。
  final bool kIsTest;

  /// W1 占位默认值（W8.5 由生成的 FlavorConfig 替换）。
  static const XboardConfig _placeholder = XboardConfig(
    subscribeUserAgent: 'Multi-Platform-Client/v0.1.0 flclash',
    devApiEndpoint: 'https://api.example.com',
    devSubscriptionEndpoint: 'https://sub.example.com',
    debug: true,
    kIsTest: false,
  );

  static XboardConfig _current = _placeholder;

  /// 当前生效配置（NFR-2 唯一接入点）。
  static XboardConfig get current => _current;

  /// bootstrap step1 绑定（W8.5 传入生成的 FlavorConfig）。
  static void bind(XboardConfig config) => _current = config;

  /// 测试用：重置回占位默认。
  static void resetForTest() => _current = _placeholder;
}
