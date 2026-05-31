/// Xboard 模块入口（conventions §1.1 / §1.4 / design「lib/xboard/ 目录结构」）。
///
/// **唯一被 FlClash 既有代码引用的入口**（接缝点 #1：`main.dart` 在 HttpOverrides 后 /
/// runApp 前调 `XboardModule.bootstrap(container)`，外层包 try/catch 隔离故障 DD-2.bis）。
///
/// **职责**：
/// - `bootstrap(container)`：同步阶段（DD-17 render-first，零网络）—— 加载 flavor /
///   早期 Sentry hook / 本地 fallback 解密 / SDK initialize / 写基础设施 provider；
///   异步阶段（runApp 后）—— 远端 Bootstrap 拉取 + endpoint 竞速 + globalUa 注入（W5）。
/// - `dispose()`：释放长生命周期资源（observer / timer / 订阅 / race controller，DD-19）。
///
/// **生命周期归属（DD-19）**：FlClash 根 ProviderContainer 全 App 不 dispose；bootstrap 是
/// runApp 前 fire-and-forget，不挂 widget 生命周期，故本模块持有并负责 dispose 自起资源。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show TokenStorage, XBoardSDK;
import 'package:shared_preferences/shared_preferences.dart';

import 'config/xboard_config.dart';
import 'l10n/content_language.dart';
import 'providers/xboard_providers.dart';
import 'widgets/xboard_consent_dialog.dart' show kXbConsentKey;

class XboardModule {
  XboardModule._();

  /// 同步阶段启动（接缝点 #1 调用点，DD-17 render-first，零网络）。
  ///
  /// **绝不抛**：所有内部异常在此全捕获（DD-2 / NFR-7）。接缝点 #1 外层再包一层兜底
  /// （DD-2.bis），双重防御保证 Xboard 故障绝不波及 FlClash 启动。
  ///
  /// [tokenStorage] 注入：测试传 fake（W0.3）；生产 W3.1 完成 `SecureStorageTokenStorage`
  /// 后由调用方注入。W1 阶段 null 时走 SDK 自带（`useMemoryStorage` 走测试路径）。
  ///
  /// [sdk] 注入：测试传 fake `XBoardSDK`（W0.3）；生产默认 `XBoardSDK.instance`。
  static Future<void> bootstrap(
    ProviderContainer container, {
    TokenStorage? tokenStorage,
    XBoardSDK? sdk,
  }) async {
    try {
      await _bootstrapSyncPhase(container, tokenStorage: tokenStorage, sdk: sdk);
    } catch (e, s) {
      // DD-2：同步阶段任何异常全吞 —— bootstrapReady 保持 false，UI gate 登录禁用 + banner。
      // W8.3 SentryBootstrap 完成后此处尽力上报。
      debugPrint('[XboardModule.bootstrap] swallowed: $e\n$s');
    }
  }

  /// 同步阶段 step 0-8（design §I / L168-247）。
  static Future<void> _bootstrapSyncPhase(
    ProviderContainer container, {
    required TokenStorage? tokenStorage,
    required XBoardSDK? sdk,
  }) async {
    // step 0：firstLaunch 检测（合规 § F / § J，W4.6 填实）。
    // 「首次进入 Xboard 模块」= 无鉴权 token **且** 无 consent 记录（xb_consent_v1）。
    // 两者都缺 → 用户从没用过「我的服务」→ firstLaunch=true（驱动首次离线提示页 §F）。
    // 任一存在（有 token / 同意过）→ 非首次。tokenStorage 为 null（W1 早期/测试）时跳过检测。
    if (tokenStorage != null) {
      try {
        final hasToken = (await tokenStorage.readToken()) != null;
        final prefs = await SharedPreferences.getInstance();
        final hasConsent = prefs.containsKey(kXbConsentKey);
        if (!hasToken && !hasConsent) {
          container.read(firstLaunchProvider.notifier).set(true);
        }
      } catch (e, s) {
        // 检测失败不阻塞 bootstrap（DD-2）；保守视为非首次（不弹首次离线页）。
        debugPrint('[XboardModule] firstLaunch detect failed: $e\n$s');
      }
    }

    // step 1：加载 flavor 配置（W8.5 prepare_flavor.dart 产物；W1 用占位默认）。
    // XboardConfig.bind(FlavorConfig.fromGenerated()) — W8.5 填实。
    final config = XboardConfig.current;

    // step 2：SentryBootstrap.installEarly + PlatformDispatcher.onError 早期 hook。
    //   W8.3 填实 6 参实现；W1 占位 no-op（不抢占 FlClash 的 FlutterError.onError）。

    // step 3：BootstrapLocalLoader.loadLocal()（W5.6 填实真实 AES-256-GCM 解密）。
    //   W1 stub：直接用 flavor 内置固定出厂 endpoint（非网络拉取），保证 step6 有值。
    final apiEndpoint = config.devApiEndpoint;
    final subscriptionEndpoint = config.devSubscriptionEndpoint;

    // step 4：SDK initialize（用本地 endpoint 作初始 baseUrl，远端拉到后 W5 热替换）。
    final instance = sdk ?? XBoardSDK.instance;
    await instance.initialize(
      apiEndpoint,
      panelType: 'xboard',
      customStorage: tokenStorage, // null → SDK 自带；测试注入 fake / W3.1 注入 SecureStorage
      useMemoryStorage: tokenStorage == null && config.kIsTest,
      userAgent: config.subscribeUserAgent,
      enableLogging: config.debug,
    );

    // step 5：SdkLogger.onLog 占位（W8.3 SentryBootstrap 完成后 wire 真实 capture）。
    //
    // W3.10：Content-Language 一次性默认 header 注入（DD-4 / F398 / F399）。
    // SDK 不主动发 Content-Language；反腐层在此（SDK initialize 后 + 首个 API 调用前）
    // 按系统 locale 映射后端 locale，写 dio 默认 header（一次性，非 per-call）。
    try {
      final backendLocale =
          mapToBackendLocale(PlatformDispatcher.instance.locale.toLanguageTag());
      // design L484 授权反腐层注入 Content-Language；SDK 无 default-headers 公共 API，
      // dio getter 是唯一注入点，受控例外。
      // ignore: deprecated_member_use
      instance.httpService.dio.options.headers[kContentLanguageHeader] =
          backendLocale;
    } catch (e, s) {
      // 注入失败不阻塞 bootstrap（DD-2 全捕获）；后端 fallback 默认 zh-CN。
      debugPrint('[XboardModule] Content-Language inject failed: $e\n$s');
    }

    // step 6：写运行期值（DD-18，非 override）。fallback 兜底即 bootstrapReady=true。
    container.read(apiEndpointProvider.notifier).set(apiEndpoint);
    container.read(subscriptionEndpointProvider.notifier).set(subscriptionEndpoint);
    container.read(xboardSdkProvider.notifier).set(instance);
    container.read(bootstrapReadyProvider.notifier).set(true);

    // step 7：占位 XboardLifecycleObserver（W5.3 完成）。
    // step 8：占位 xboardConnectivityProvider（W5.4 完成，复用 DD-5 单一数据源）。
  }

  /// 释放模块自起的长生命周期资源（DD-19）。
  static Future<void> dispose() async {
    // W5 填实：移除 lifecycle observer / 取消心跳 timer / 关 connectivity 订阅 /
    // dispose EndpointRaceController。
  }
}
