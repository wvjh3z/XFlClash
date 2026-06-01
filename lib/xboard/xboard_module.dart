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

import '../providers/config.dart' show patchClashConfigProvider;
import '../providers/app.dart' show initProvider;
import 'config/xboard_config.dart';
import 'l10n/content_language.dart';
import 'models/bootstrap_payload.dart';
import 'providers/xboard_providers.dart';
import 'services/bootstrap_decryptor.dart';
import 'services/bootstrap_fetcher.dart';
import 'services/bootstrap_local_loader.dart';
import 'services/endpoint_race_controller.dart';
import 'services/sentry_bootstrap.dart';
import 'services/xboard_lifecycle_observer.dart';
import 'widgets/xboard_consent_dialog.dart' show kXbConsentKey;

class XboardModule {
  XboardModule._();

  /// 自起 lifecycle observer（DD-19，dispose 时摘除）。
  static XboardLifecycleObserver? _lifecycleObserver;

  /// 自起 endpoint 竞速控制器（DD-19）。
  static EndpointRaceController? _raceController;

  /// seam #7 globalUa 注入的 initProvider 监听句柄（dispose 时关）。
  static ProviderSubscription<bool>? _initListener;

  /// 同步阶段 loadLocal() 解出的本地 payload（异步阶段远端失败时的竞速候选）。
  static BootstrapPayload? _localPayload;

  /// 异步阶段 single-flight 守卫（避免重复 fire）。
  static bool _asyncStarted = false;

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
    @visibleForTesting EndpointProbe? debugProbe,
  }) async {
    try {
      await _bootstrapSyncPhase(container,
          tokenStorage: tokenStorage, sdk: sdk, debugProbe: debugProbe);
    } catch (e, s) {
      // DD-2：同步阶段任何异常全吞 —— bootstrapReady 保持 false，UI gate 登录禁用 + banner。
      // W8.3 SentryBootstrap 完成后此处尽力上报。
      debugPrint('[XboardModule.bootstrap] swallowed: $e\n$s');
    }
  }

  /// 异步阶段（接缝点 #1.bis 调用点，runApp **后** fire-and-forget，R15.B/C/H）。
  ///
  /// **DD-17 render-first**：本方法绝不在 runApp 前 await——首屏立即用同步阶段的本地/出厂
  /// endpoint 渲染；远端 Bootstrap + endpoint 竞速 + 热替换全在后台跑，拉到更优 endpoint 后
  /// 通过 `EndpointRaceController.onApiSwitch` → `switchBaseUrl` 热替换（已加载 UI 不重建）。
  ///
  /// **编排**（永不抛，DD-2 / Property 1）：
  ///   1. 远端拉取 `fetchRemote(bootstrapUrls)`（串行 + 30s 预算 + 严格 TLS θ-1）；
  ///   2. 成功 → 写缓存密文（DD-22 / R15.D.25）+ 用远端 payload 竞速；
  ///      失败 → 退回同步阶段本地 payload（`_localPayload`）竞速；二者皆无 → 不竞速（沿用出厂）；
  ///   3. `raceApi` + `raceSubscription` → 最快可达者经 `onApiSwitch` 回调热替换 SDK baseUrl。
  ///
  /// `bootstrap()` 完成（SDK initialized + race controller 就绪）后由接缝点 #1 调用。
  static Future<void> bootstrapAsync(ProviderContainer container) async {
    if (_asyncStarted) return; // single-flight
    _asyncStarted = true;
    try {
      await _bootstrapAsyncPhase(container);
    } catch (e, s) {
      // DD-2：异步阶段任何异常全吞——失败沿用同步阶段 endpoint，绝不波及已渲染 UI。
      debugPrint('[XboardModule.bootstrapAsync] swallowed: $e\n$s');
    }
  }

  static Future<void> _bootstrapAsyncPhase(ProviderContainer container) async {
    final config = XboardConfig.current;
    final race = _raceController;
    if (race == null) {
      // 同步阶段 race controller 未就绪（如 bootstrap 失败）→ 无法竞速，沿用出厂 endpoint。
      debugPrint('[XboardModule] async: race controller 未就绪，跳过竞速');
      return;
    }

    SentryBootstrap.tagBootstrap(stage: 'async_start');

    // 1. 远端拉取（仅在 flavor 配了镜像时；否则直接用本地 payload 竞速）。
    BootstrapPayload? payload;
    if (config.bootstrapUrls.isNotEmpty) {
      final decryptor = BootstrapDecryptor(aesKey: config.bootstrapAesKeyBytes);
      final fetcher = BootstrapFetcher(decryptor: decryptor);
      final result = await fetcher.fetchRemote(config.bootstrapUrls);
      if (result.isSuccess) {
        payload = result.payload;
        // 2. 写缓存密文（下次冷启同步阶段 loadLocal 命中，DD-22 / R15.D.25）。
        final env = result.winnerEnvelope;
        if (env != null) {
          await BootstrapLocalLoader(decryptor: decryptor).writeCache(env);
        }
      }
    }

    // 远端失败 → 退回同步阶段本地 payload（cache / fallback 解出的，R15.B 三级降级）。
    payload ??= _localPayload;
    if (payload == null || !payload.isValid) {
      SentryBootstrap.tagBootstrap(stage: 'async_no_endpoints');
      return; // 无任何 endpoint 候选 → 沿用同步阶段出厂 endpoint。
    }

    // 3. endpoint 竞速 → 最快可达者经 onApiSwitch 回调热替换 SDK baseUrl + 写 provider。
    await race.raceApi(payload.apiEndpoints);
    await race.raceSubscription(payload.subscriptionEndpoints);

    SentryBootstrap.tagBootstrap(stage: 'async_done');
  }

  /// 同步阶段 step 0-8（design §I / L168-247）。
  static Future<void> _bootstrapSyncPhase(
    ProviderContainer container, {
    required TokenStorage? tokenStorage,
    required XBoardSDK? sdk,
    EndpointProbe? debugProbe,
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

    // DD-23：flavor.id + bootstrap 起始阶段 tag（W5.7 / λ-4）。
    SentryBootstrap.tagFlavor(config.flavorId);
    SentryBootstrap.tagBootstrap(stage: 'sync_start');

    // step 2：SentryBootstrap.installEarly + PlatformDispatcher.onError 早期 hook。
    //   W8.3 填实 6 参实现；W1 占位 no-op（不抢占 FlClash 的 FlutterError.onError）。

    // step 3：BootstrapLocalLoader.loadLocal()（W5.6 真实 AES-256-GCM 解密，零网络）。
    //   优先级：本地缓存密文 → 出厂 fallback 资产 → null（双双损坏走 config 出厂 endpoint 兜底）。
    //   解出的 payload 暂存（_localPayload），异步阶段远端拉取失败时作竞速候选。
    final decryptor = BootstrapDecryptor(aesKey: config.bootstrapAesKeyBytes);
    String apiEndpoint = config.devApiEndpoint;
    String subscriptionEndpoint = config.devSubscriptionEndpoint;
    try {
      final local = await BootstrapLocalLoader(decryptor: decryptor).loadLocal();
      final payload = local.payload;
      if (payload != null && payload.isValid) {
        _localPayload = payload;
        apiEndpoint = payload.apiEndpoints.first;
        subscriptionEndpoint = payload.subscriptionEndpoints.first;
      }
    } catch (e, s) {
      // 本地加载失败不阻塞（DD-2 / Property 1）；沿用 config 出厂 endpoint。
      debugPrint('[XboardModule] loadLocal failed: $e\n$s');
    }

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

    // step 7：XboardLifecycleObserver（W5.3）—— 自挂 observer + endpoint 竞速控制器。
    // 各子步骤独立 try/catch：一个失败（如 test 无 WidgetsBinding）不阻断其余（含 seam #7）。
    try {
      _raceController = EndpointRaceController(
        probe: debugProbe, // 生产 null → 默认真实 Dio 探针；测试注入 fake。
        onApiSwitch: (ep) {
          try {
            instance.switchBaseUrl(ep);
          } catch (_) {}
          container.read(apiEndpointProvider.notifier).set(ep);
          SentryBootstrap.tagEndpoint(current: ep); // DD-23 endpoint.current
        },
        onSubscriptionSwitch: (ep) =>
            container.read(subscriptionEndpointProvider.notifier).set(ep),
      );
      _lifecycleObserver =
          XboardLifecycleObserver(raceController: _raceController!)..attach();
    } catch (e, s) {
      debugPrint('[XboardModule] lifecycle observer wire failed: $e\n$s');
    }

    // seam #7（W5.5）：等 initProvider==true（globalState.attach 完成）后强制注入 globalUa。
    try {
      _wireGlobalUaInjection(container);
    } catch (e, s) {
      debugPrint('[XboardModule] globalUa wire failed: $e\n$s');
    }

    // DD-23：bootstrap 同步阶段完成 tag（W5.7）。
    SentryBootstrap.tagBootstrap(stage: 'sync_done');

    // step 8：connectivity（W5.4 xboardConnectivityProvider 自起 StreamProvider，
    // UI/race 通过 ref.watch/listen 复用，不在此裸 listen，DD-5/E12）。
  }

  /// seam #7 globalUa 强制注入（F221 / DD-12 / R7 AC 0.bis）。
  ///
  /// 监听 `initProvider`，==true（globalState.attach 完成）时强制写 globalUa（含单一 flclash 子串）。
  /// **DD-12**：不盲目复用用户值（防用户改 globalUa 成 clash-verge 致 R7 协议歧义崩）。
  static void _wireGlobalUaInjection(ProviderContainer container) {
    void inject() {
      try {
        final ua = XboardConfig.current.subscribeUserAgent;
        container
            .read(patchClashConfigProvider.notifier)
            .update((s) => s.copyWith(globalUa: ua));
      } catch (e, s) {
        debugPrint('[XboardModule] globalUa inject failed: $e\n$s');
      }
    }

    // 已就绪则立即注入；否则监听首次 true。
    if (container.read(initProvider)) {
      inject();
    } else {
      _initListener = container.listen<bool>(initProvider, (prev, next) {
        if (next) {
          inject();
          _initListener?.close();
          _initListener = null;
        }
      });
    }
  }

  /// 释放模块自起的长生命周期资源（DD-19 顺序：摘 observer → 关监听 → race dispose）。
  static Future<void> dispose() async {
    // 1. 先摘 observer（停止接收 lifecycle 事件，避免 race 已 dispose 后还触发竞速）。
    _lifecycleObserver?.dispose();
    _lifecycleObserver = null;
    // 2. 关 seam #7 initProvider 监听。
    _initListener?.close();
    _initListener = null;
    // 3. dispose endpoint 竞速控制器（最后，前面已无人触发它）。
    _raceController?.dispose();
    _raceController = null;
    // 4. 重置异步阶段状态（允许下次 bootstrap 重新跑；测试 teardown 复用）。
    _asyncStarted = false;
    _localPayload = null;
  }
}
