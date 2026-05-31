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
    this.brandColor = 0xFFD92E1A,
    this.termsUrl = 'https://example.com/terms',
    this.privacyUrl = 'https://example.com/privacy',
    this.dataResidency = 'Hong Kong',
    this.dataController = 'Example Tech Co., Ltd.',
    this.supportEmail = 'support@example.com',
    this.bootstrapUrls = const <String>[],
    this.bootstrapAesKeyBytes,
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

  /// 品牌主色（flavor 注入，UI kit XbBrandTheme 用；默认品牌红 D3）。
  final int brandColor;

  /// 用户协议链接（合规 § A，flavor 必填；W8.5 prepare_flavor fail-fast 校验）。
  final String termsUrl;

  /// 隐私政策链接（合规 § A，flavor 必填）。
  final String privacyUrl;

  /// 数据存储位置（合规 § A，自由文本，consent dialog 展示）。
  final String dataResidency;

  /// 数据控制方（合规 § A，GDPR 法律实体名）。
  final String dataController;

  /// 客服邮箱（合规 § B，账号注销 mailto 用）。
  final String supportEmail;

  /// Bootstrap 远端镜像 URL 列表（R15；运行时地址不入 Dart/yaml，仅 flavor 注入 bootstrap 入口）。
  final List<String> bootstrapUrls;

  /// Bootstrap AES-256 解密 key（32 字节；编译期注入，D58 不进 git）。null = 未配置（降级）。
  final List<int>? bootstrapAesKeyBytes;

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
