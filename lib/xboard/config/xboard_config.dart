/// Xboard 运行期配置接入点（design §E / NFR-2）。
///
/// **配置来源（W8.5 修订：dart-define 而非生成 .dart）**：
/// - 默认值（本文件 [_placeholder]）：dev/test 直跑、无 flavor 注入时用。
/// - 生产/品牌构建：`tool/prepare_flavor.dart` 读 flavor.yaml → 生成 `flavor_defines.json`
///   （gitignored，含 CI 注入 aesKey/sentryDsn）→ `flutter build --dart-define-from-file=flavor_defines.json`
///   → [XboardConfig.fromEnvironment] 编译期读入。**committed 代码零 import 生成物**（恒可编译，
///   不破 CI/测试）；密钥只在 build 时经 dart-define 流入，绝不进 git（D58）。
///
/// **铁律（NFR-2 / Property 19）**：任何「会因发行不同而变化」的值（应用名 / 包名 /
/// 品牌色 / API URL / 订阅 UA）一律走 `XboardConfig.current`，业务代码 0 处硬编码。
library;

import 'dart:convert';

/// flavor 配置的运行期视图（W8.5 prepare_flavor.dart 生成实体后替换占位字段）。
class XboardConfig {
  const XboardConfig({
    required this.subscribeUserAgent,
    required this.devApiEndpoint,
    required this.devSubscriptionEndpoint,
    required this.debug,
    required this.kIsTest,
    this.flavorId = 'brand_a',
    this.brandColor = 0xFFD92E1A,
    this.termsUrl = 'https://example.com/terms',
    this.privacyUrl = 'https://example.com/privacy',
    this.dataResidency = 'Hong Kong',
    this.dataController = 'Example Tech Co., Ltd.',
    this.supportEmail = 'support@example.com',
    this.bootstrapUrls = const <String>[],
    this.bootstrapAesKeyBytes,
    this.subscriptionAesKeyBytes,
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

  /// flavor 标识（DD-23 `flavor.id` Sentry tag；W8.5 prepare_flavor 注入，默认 brand_a）。
  final String flavorId;

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

  /// R4.1 加密订阅 AES-256 解密 key（32 字节；编译期注入）。
  /// null → fallback 到 [bootstrapAesKeyBytes]（contract 0-B：key 可与 bootstrap 同可不同；
  /// 当前部署同一把 key，未单独注入时复用 bootstrap key）。
  final List<int>? subscriptionAesKeyBytes;

  /// R4.1 加密订阅解密用 key：优先专用 key，未注入则复用 bootstrap key（当前部署同一把）。
  List<int>? get effectiveSubscriptionAesKeyBytes =>
      subscriptionAesKeyBytes ?? bootstrapAesKeyBytes;

  /// 从 dart-define 编译期常量构造（W8.5 生产/品牌构建路径）。
  ///
  /// 读 `--dart-define-from-file=flavor_defines.json` 注入的常量；任一未注入则回退到
  /// [_placeholder] 同名默认（保证无 flavor 注入时也能跑）。`XB_BOOTSTRAP_URLS` 是逗号分隔串，
  /// `XB_AES_KEY_B64` 是 base64（空/非法 → null 降级）。**全 const 读取**（编译期内联，
  /// 业务代码无 import 生成物，CI/测试零依赖）。
  factory XboardConfig.fromEnvironment() {
    const ua = String.fromEnvironment('XB_SUBSCRIBE_UA',
        defaultValue: 'Multi-Platform-Client/v0.1.0 flclash');
    const api =
        String.fromEnvironment('XB_API_ENDPOINT', defaultValue: 'https://api.example.com');
    const sub = String.fromEnvironment('XB_SUBSCRIPTION_ENDPOINT',
        defaultValue: 'https://sub.example.com');
    const debug = bool.fromEnvironment('XB_DEBUG', defaultValue: true);
    const flavorId = String.fromEnvironment('XB_FLAVOR_ID', defaultValue: 'brand_a');
    const brandColor = int.fromEnvironment('XB_BRAND_COLOR', defaultValue: 0xFFD92E1A);
    const termsUrl = String.fromEnvironment('XB_TERMS_URL',
        defaultValue: 'https://example.com/terms');
    const privacyUrl = String.fromEnvironment('XB_PRIVACY_URL',
        defaultValue: 'https://example.com/privacy');
    const dataResidency =
        String.fromEnvironment('XB_DATA_RESIDENCY', defaultValue: 'Hong Kong');
    const dataController = String.fromEnvironment('XB_DATA_CONTROLLER',
        defaultValue: 'Example Tech Co., Ltd.');
    const supportEmail = String.fromEnvironment('XB_SUPPORT_EMAIL',
        defaultValue: 'support@example.com');
    const urlsCsv = String.fromEnvironment('XB_BOOTSTRAP_URLS', defaultValue: '');
    const aesKeyB64 = String.fromEnvironment('XB_AES_KEY_B64', defaultValue: '');
    const subAesKeyB64 =
        String.fromEnvironment('XB_SUB_AES_KEY_B64', defaultValue: '');

    final urls = urlsCsv.isEmpty
        ? const <String>[]
        : urlsCsv.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    List<int>? aesBytes;
    if (aesKeyB64.isNotEmpty) {
      try {
        final decoded = base64.decode(aesKeyB64);
        if (decoded.length == 32) aesBytes = decoded;
      } catch (_) {
        aesBytes = null; // 非法 base64 → 降级（永不抛）
      }
    }
    // R4.1 加密订阅专用 key（可选；未注入则运行期 fallback 到 bootstrap key）。
    List<int>? subAesBytes;
    if (subAesKeyB64.isNotEmpty) {
      try {
        final decoded = base64.decode(subAesKeyB64);
        if (decoded.length == 32) subAesBytes = decoded;
      } catch (_) {
        subAesBytes = null;
      }
    }

    return XboardConfig(
      subscribeUserAgent: ua,
      devApiEndpoint: api,
      devSubscriptionEndpoint: sub,
      debug: debug,
      kIsTest: false,
      flavorId: flavorId,
      brandColor: brandColor,
      termsUrl: termsUrl,
      privacyUrl: privacyUrl,
      dataResidency: dataResidency,
      dataController: dataController,
      supportEmail: supportEmail,
      bootstrapUrls: urls,
      bootstrapAesKeyBytes: aesBytes,
      subscriptionAesKeyBytes: subAesBytes,
    );
  }

  /// 占位默认值（dev/test 直跑、无 dart-define 注入时用；与 [fromEnvironment] 默认值一致）。
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

  /// bootstrap step1 绑定（生产传 [XboardConfig.fromEnvironment]；测试传自定义实例）。
  static void bind(XboardConfig config) => _current = config;

  /// 测试用：重置回占位默认。
  static void resetForTest() => _current = _placeholder;
}
