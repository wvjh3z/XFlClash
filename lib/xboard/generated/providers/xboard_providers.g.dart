// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../providers/xboard_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 当前生效的 API endpoint（DD-18 写运行期值，非 override）。
///
/// 写入时机：bootstrap step6（同步）+ 异步阶段 `switchBaseUrl`。
/// 默认 `''`（未就绪占位，design §E）。**UI 不 watch**（Property 21）。

@ProviderFor(ApiEndpoint)
final apiEndpointProvider = ApiEndpointProvider._();

/// 当前生效的 API endpoint（DD-18 写运行期值，非 override）。
///
/// 写入时机：bootstrap step6（同步）+ 异步阶段 `switchBaseUrl`。
/// 默认 `''`（未就绪占位，design §E）。**UI 不 watch**（Property 21）。
final class ApiEndpointProvider extends $NotifierProvider<ApiEndpoint, String> {
  /// 当前生效的 API endpoint（DD-18 写运行期值，非 override）。
  ///
  /// 写入时机：bootstrap step6（同步）+ 异步阶段 `switchBaseUrl`。
  /// 默认 `''`（未就绪占位，design §E）。**UI 不 watch**（Property 21）。
  ApiEndpointProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'apiEndpointProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$apiEndpointHash();

  @$internal
  @override
  ApiEndpoint create() => ApiEndpoint();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String>(value),
    );
  }
}

String _$apiEndpointHash() => r'22e1c3063cceb19174ca054460e32b193227da53';

/// 当前生效的 API endpoint（DD-18 写运行期值，非 override）。
///
/// 写入时机：bootstrap step6（同步）+ 异步阶段 `switchBaseUrl`。
/// 默认 `''`（未就绪占位，design §E）。**UI 不 watch**（Property 21）。

abstract class _$ApiEndpoint extends $Notifier<String> {
  String build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<String, String>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<String, String>,
              String,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// 当前生效的订阅 endpoint（host）。写入时机同 [ApiEndpoint]。**UI 不 watch**（Property 21）。

@ProviderFor(SubscriptionEndpoint)
final subscriptionEndpointProvider = SubscriptionEndpointProvider._();

/// 当前生效的订阅 endpoint（host）。写入时机同 [ApiEndpoint]。**UI 不 watch**（Property 21）。
final class SubscriptionEndpointProvider
    extends $NotifierProvider<SubscriptionEndpoint, String> {
  /// 当前生效的订阅 endpoint（host）。写入时机同 [ApiEndpoint]。**UI 不 watch**（Property 21）。
  SubscriptionEndpointProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'subscriptionEndpointProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$subscriptionEndpointHash();

  @$internal
  @override
  SubscriptionEndpoint create() => SubscriptionEndpoint();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String>(value),
    );
  }
}

String _$subscriptionEndpointHash() =>
    r'b8feb4ea2629b6a0213e23a769b00fff15e45467';

/// 当前生效的订阅 endpoint（host）。写入时机同 [ApiEndpoint]。**UI 不 watch**（Property 21）。

abstract class _$SubscriptionEndpoint extends $Notifier<String> {
  String build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<String, String>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<String, String>,
              String,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// SDK 单例（bootstrap step6 写 `XBoardSDK.instance`）。⚠️ 仅反腐层 read，UI 不碰。
///
/// 默认 `null`（未 initialize）；bootstrap 成功后写实例。

@ProviderFor(XboardSdk)
final xboardSdkProvider = XboardSdkProvider._();

/// SDK 单例（bootstrap step6 写 `XBoardSDK.instance`）。⚠️ 仅反腐层 read，UI 不碰。
///
/// 默认 `null`（未 initialize）；bootstrap 成功后写实例。
final class XboardSdkProvider extends $NotifierProvider<XboardSdk, XBoardSDK?> {
  /// SDK 单例（bootstrap step6 写 `XBoardSDK.instance`）。⚠️ 仅反腐层 read，UI 不碰。
  ///
  /// 默认 `null`（未 initialize）；bootstrap 成功后写实例。
  XboardSdkProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'xboardSdkProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$xboardSdkHash();

  @$internal
  @override
  XboardSdk create() => XboardSdk();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(XBoardSDK? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<XBoardSDK?>(value),
    );
  }
}

String _$xboardSdkHash() => r'8f17fa69eecf8ab2470a4410c74df9611c20c652';

/// SDK 单例（bootstrap step6 写 `XBoardSDK.instance`）。⚠️ 仅反腐层 read，UI 不碰。
///
/// 默认 `null`（未 initialize）；bootstrap 成功后写实例。

abstract class _$XboardSdk extends $Notifier<XBoardSDK?> {
  XBoardSDK? build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<XBoardSDK?, XBoardSDK?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<XBoardSDK?, XBoardSDK?>,
              XBoardSDK?,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// SDK 是否已 initialize（DD-17 / F15）。
///
/// 同步阶段 fallback 兜底即 true；仅 fallback 损坏为 false（登录禁用 + banner）。
/// ✅ UI 可 watch（gate 登录入口 + 异常 banner）。

@ProviderFor(BootstrapReady)
final bootstrapReadyProvider = BootstrapReadyProvider._();

/// SDK 是否已 initialize（DD-17 / F15）。
///
/// 同步阶段 fallback 兜底即 true；仅 fallback 损坏为 false（登录禁用 + banner）。
/// ✅ UI 可 watch（gate 登录入口 + 异常 banner）。
final class BootstrapReadyProvider
    extends $NotifierProvider<BootstrapReady, bool> {
  /// SDK 是否已 initialize（DD-17 / F15）。
  ///
  /// 同步阶段 fallback 兜底即 true；仅 fallback 损坏为 false（登录禁用 + banner）。
  /// ✅ UI 可 watch（gate 登录入口 + 异常 banner）。
  BootstrapReadyProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'bootstrapReadyProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$bootstrapReadyHash();

  @$internal
  @override
  BootstrapReady create() => BootstrapReady();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$bootstrapReadyHash() => r'da5ba866b7aa146bb585e78fe230fe3fdf9c944c';

/// SDK 是否已 initialize（DD-17 / F15）。
///
/// 同步阶段 fallback 兜底即 true；仅 fallback 损坏为 false（登录禁用 + banner）。
/// ✅ UI 可 watch（gate 登录入口 + 异常 banner）。

abstract class _$BootstrapReady extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// 是否首次进入 Xboard 模块（design §F / §J）。
///
/// bootstrap step0 检测「无 token + 无 `xb_consent_v1`」后写 true（一次性，不回退）。
/// ✅ UI 可 watch（合规 §F 首次离线检测 splash）。

@ProviderFor(FirstLaunch)
final firstLaunchProvider = FirstLaunchProvider._();

/// 是否首次进入 Xboard 模块（design §F / §J）。
///
/// bootstrap step0 检测「无 token + 无 `xb_consent_v1`」后写 true（一次性，不回退）。
/// ✅ UI 可 watch（合规 §F 首次离线检测 splash）。
final class FirstLaunchProvider extends $NotifierProvider<FirstLaunch, bool> {
  /// 是否首次进入 Xboard 模块（design §F / §J）。
  ///
  /// bootstrap step0 检测「无 token + 无 `xb_consent_v1`」后写 true（一次性，不回退）。
  /// ✅ UI 可 watch（合规 §F 首次离线检测 splash）。
  FirstLaunchProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'firstLaunchProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$firstLaunchHash();

  @$internal
  @override
  FirstLaunch create() => FirstLaunch();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$firstLaunchHash() => r'4c2763d56f2c3d47f604fbd0c39077e13393b38d';

/// 是否首次进入 Xboard 模块（design §F / §J）。
///
/// bootstrap step0 检测「无 token + 无 `xb_consent_v1`」后写 true（一次性，不回退）。
/// ✅ UI 可 watch（合规 §F 首次离线检测 splash）。

abstract class _$FirstLaunch extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// 反腐层单例（conventions §2.1 / W2.2）。
///
/// 依赖 `xboardSdkProvider`（bootstrap step6 写 `XBoardSDK.instance`）；SDK 就绪后
/// 构造注入式 `XboardServiceImpl`（决策 #9）。bootstrap 完成前 SDK 为 null → 抛
/// StateError（UI 应先 gate `bootstrapReadyProvider`，不在未就绪时调反腐层）。

@ProviderFor(xboardService)
final xboardServiceProvider = XboardServiceProvider._();

/// 反腐层单例（conventions §2.1 / W2.2）。
///
/// 依赖 `xboardSdkProvider`（bootstrap step6 写 `XBoardSDK.instance`）；SDK 就绪后
/// 构造注入式 `XboardServiceImpl`（决策 #9）。bootstrap 完成前 SDK 为 null → 抛
/// StateError（UI 应先 gate `bootstrapReadyProvider`，不在未就绪时调反腐层）。

final class XboardServiceProvider
    extends $FunctionalProvider<XboardService, XboardService, XboardService>
    with $Provider<XboardService> {
  /// 反腐层单例（conventions §2.1 / W2.2）。
  ///
  /// 依赖 `xboardSdkProvider`（bootstrap step6 写 `XBoardSDK.instance`）；SDK 就绪后
  /// 构造注入式 `XboardServiceImpl`（决策 #9）。bootstrap 完成前 SDK 为 null → 抛
  /// StateError（UI 应先 gate `bootstrapReadyProvider`，不在未就绪时调反腐层）。
  XboardServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'xboardServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$xboardServiceHash();

  @$internal
  @override
  $ProviderElement<XboardService> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  XboardService create(Ref ref) {
    return xboardService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(XboardService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<XboardService>(value),
    );
  }
}

String _$xboardServiceHash() => r'24045bd92428eca0faf65f86c90564595add1487';

/// 注入的 TokenStorage（bootstrap step4 写真实实现：SecureStorage / AES-SharedPrefs / Memory）。
///
/// 订阅同步服务用它取 userIdHash（profile 外挂索引绑定，C7 退出登录删）。null = bootstrap 未
/// 注入（测试 / 早期）→ 订阅服务 provider 不可用（callers 先 gate authenticated 隐含已注入）。

@ProviderFor(InjectedTokenStorage)
final injectedTokenStorageProvider = InjectedTokenStorageProvider._();

/// 注入的 TokenStorage（bootstrap step4 写真实实现：SecureStorage / AES-SharedPrefs / Memory）。
///
/// 订阅同步服务用它取 userIdHash（profile 外挂索引绑定，C7 退出登录删）。null = bootstrap 未
/// 注入（测试 / 早期）→ 订阅服务 provider 不可用（callers 先 gate authenticated 隐含已注入）。
final class InjectedTokenStorageProvider
    extends $NotifierProvider<InjectedTokenStorage, TokenStorage?> {
  /// 注入的 TokenStorage（bootstrap step4 写真实实现：SecureStorage / AES-SharedPrefs / Memory）。
  ///
  /// 订阅同步服务用它取 userIdHash（profile 外挂索引绑定，C7 退出登录删）。null = bootstrap 未
  /// 注入（测试 / 早期）→ 订阅服务 provider 不可用（callers 先 gate authenticated 隐含已注入）。
  InjectedTokenStorageProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'injectedTokenStorageProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$injectedTokenStorageHash();

  @$internal
  @override
  InjectedTokenStorage create() => InjectedTokenStorage();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(TokenStorage? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<TokenStorage?>(value),
    );
  }
}

String _$injectedTokenStorageHash() =>
    r'cf6e5bfde6e63e3b5604f1114f1d3c1f5b892055';

/// 注入的 TokenStorage（bootstrap step4 写真实实现：SecureStorage / AES-SharedPrefs / Memory）。
///
/// 订阅同步服务用它取 userIdHash（profile 外挂索引绑定，C7 退出登录删）。null = bootstrap 未
/// 注入（测试 / 早期）→ 订阅服务 provider 不可用（callers 先 gate authenticated 隐含已注入）。

abstract class _$InjectedTokenStorage extends $Notifier<TokenStorage?> {
  TokenStorage? build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<TokenStorage?, TokenStorage?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<TokenStorage?, TokenStorage?>,
              TokenStorage?,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// 注入的 endpoint 竞速控制器（bootstrap step7 写）。订阅服务读它取 `subscriptionCandidates()`
/// （R4.2 竞速候选 host 串）。null = 未就绪 → 候选为空（[EncryptedSubscriptionService] 退回原 URL host 兜底）。

@ProviderFor(InjectedRaceController)
final injectedRaceControllerProvider = InjectedRaceControllerProvider._();

/// 注入的 endpoint 竞速控制器（bootstrap step7 写）。订阅服务读它取 `subscriptionCandidates()`
/// （R4.2 竞速候选 host 串）。null = 未就绪 → 候选为空（[EncryptedSubscriptionService] 退回原 URL host 兜底）。
final class InjectedRaceControllerProvider
    extends $NotifierProvider<InjectedRaceController, EndpointRaceController?> {
  /// 注入的 endpoint 竞速控制器（bootstrap step7 写）。订阅服务读它取 `subscriptionCandidates()`
  /// （R4.2 竞速候选 host 串）。null = 未就绪 → 候选为空（[EncryptedSubscriptionService] 退回原 URL host 兜底）。
  InjectedRaceControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'injectedRaceControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$injectedRaceControllerHash();

  @$internal
  @override
  InjectedRaceController create() => InjectedRaceController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(EndpointRaceController? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<EndpointRaceController?>(value),
    );
  }
}

String _$injectedRaceControllerHash() =>
    r'74977d64498904fbdbf882534845a65978fed66e';

/// 注入的 endpoint 竞速控制器（bootstrap step7 写）。订阅服务读它取 `subscriptionCandidates()`
/// （R4.2 竞速候选 host 串）。null = 未就绪 → 候选为空（[EncryptedSubscriptionService] 退回原 URL host 兜底）。

abstract class _$InjectedRaceController
    extends $Notifier<EndpointRaceController?> {
  EndpointRaceController? build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref =
        this.ref as $Ref<EndpointRaceController?, EndpointRaceController?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<EndpointRaceController?, EndpointRaceController?>,
              EndpointRaceController?,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// Xboard 外挂索引数据库（决策 #3 / R7.6）—— keepAlive 单例，dispose 时关闭。

@ProviderFor(xboardDatabase)
final xboardDatabaseProvider = XboardDatabaseProvider._();

/// Xboard 外挂索引数据库（决策 #3 / R7.6）—— keepAlive 单例，dispose 时关闭。

final class XboardDatabaseProvider
    extends $FunctionalProvider<XboardDatabase, XboardDatabase, XboardDatabase>
    with $Provider<XboardDatabase> {
  /// Xboard 外挂索引数据库（决策 #3 / R7.6）—— keepAlive 单例，dispose 时关闭。
  XboardDatabaseProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'xboardDatabaseProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$xboardDatabaseHash();

  @$internal
  @override
  $ProviderElement<XboardDatabase> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  XboardDatabase create(Ref ref) {
    return xboardDatabase(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(XboardDatabase value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<XboardDatabase>(value),
    );
  }
}

String _$xboardDatabaseHash() => r'230d61eb32c0427bf8d4dacac9c89573752e2600';

/// R4.1/R4.2 加密订阅拉取服务（decryptor 用订阅 AES key，未注入则 fallback bootstrap key）。

@ProviderFor(encryptedSubscriptionService)
final encryptedSubscriptionServiceProvider =
    EncryptedSubscriptionServiceProvider._();

/// R4.1/R4.2 加密订阅拉取服务（decryptor 用订阅 AES key，未注入则 fallback bootstrap key）。

final class EncryptedSubscriptionServiceProvider
    extends
        $FunctionalProvider<
          EncryptedSubscriptionService,
          EncryptedSubscriptionService,
          EncryptedSubscriptionService
        >
    with $Provider<EncryptedSubscriptionService> {
  /// R4.1/R4.2 加密订阅拉取服务（decryptor 用订阅 AES key，未注入则 fallback bootstrap key）。
  EncryptedSubscriptionServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'encryptedSubscriptionServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$encryptedSubscriptionServiceHash();

  @$internal
  @override
  $ProviderElement<EncryptedSubscriptionService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  EncryptedSubscriptionService create(Ref ref) {
    return encryptedSubscriptionService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(EncryptedSubscriptionService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<EncryptedSubscriptionService>(value),
    );
  }
}

String _$encryptedSubscriptionServiceHash() =>
    r'ddfe859e48bb3bd9c00e9b868c0ad229ba5419fb';

/// R4.6 订阅自动同步服务（组装：反腐层 + 加密订阅 + profile 端口 + DB + tokenStorage + 竞速候选）。
///
/// **gate**：依赖 `xboardServiceProvider`（SDK 未就绪抛 StateError）+ tokenStorage 已注入
/// （未注入抛 StateError）；callers 先 gate authenticated（隐含 bootstrap 完成 + token 注入）。

@ProviderFor(subscriptionService)
final subscriptionServiceProvider = SubscriptionServiceProvider._();

/// R4.6 订阅自动同步服务（组装：反腐层 + 加密订阅 + profile 端口 + DB + tokenStorage + 竞速候选）。
///
/// **gate**：依赖 `xboardServiceProvider`（SDK 未就绪抛 StateError）+ tokenStorage 已注入
/// （未注入抛 StateError）；callers 先 gate authenticated（隐含 bootstrap 完成 + token 注入）。

final class SubscriptionServiceProvider
    extends
        $FunctionalProvider<
          XboardSubscriptionService,
          XboardSubscriptionService,
          XboardSubscriptionService
        >
    with $Provider<XboardSubscriptionService> {
  /// R4.6 订阅自动同步服务（组装：反腐层 + 加密订阅 + profile 端口 + DB + tokenStorage + 竞速候选）。
  ///
  /// **gate**：依赖 `xboardServiceProvider`（SDK 未就绪抛 StateError）+ tokenStorage 已注入
  /// （未注入抛 StateError）；callers 先 gate authenticated（隐含 bootstrap 完成 + token 注入）。
  SubscriptionServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'subscriptionServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$subscriptionServiceHash();

  @$internal
  @override
  $ProviderElement<XboardSubscriptionService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  XboardSubscriptionService create(Ref ref) {
    return subscriptionService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(XboardSubscriptionService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<XboardSubscriptionService>(value),
    );
  }
}

String _$subscriptionServiceHash() =>
    r'e83e51769eed41263c625fc502ec47113a3ee220';
