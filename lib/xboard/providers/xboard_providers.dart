/// Xboard 基础设施 provider 集合（DD-18 / DD-19 / Property 21 / design §I）。
///
/// **5 个 keepAlive 基础设施 provider**（`authStateProvider` 不在此，由 W3.2 认证模块
/// 单独建，避免同文件 codegen 耦合）：
/// - `apiEndpointProvider` / `subscriptionEndpointProvider`：当前竞速 endpoint（DD-18 写运行期值）
/// - `xboardSdkProvider`：bootstrap step6 写 XBoardSDK 实例（仅反腐层 read）
/// - `bootstrapReadyProvider`：SDK 是否已 initialize（UI gate 登录 + banner）
/// - `firstLaunchProvider`：是否首次进入 Xboard 模块（合规 §F 首次离线检测）
///
/// **全部 keepAlive（DD-19）**：bootstrap 写值、生命周期与 App 同寿；codegen 默认 autoDispose
/// 会回收 SDK 单例 provider，故强制 keepAlive。
///
/// **UI watch 边界（Property 21 / design §I 表）**：
/// - api/subscription endpoint：❌ UI 不 watch（endpoint 热替换不重建已加载 UI）
/// - xboardSdk：⚠️ 仅反腐层 read
/// - bootstrapReady / firstLaunch：✅ UI 可 watch
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../sdk/xboard_service.dart';
import '../sdk/xboard_service_impl.dart';

part '../generated/providers/xboard_providers.g.dart';

/// 当前生效的 API endpoint（DD-18 写运行期值，非 override）。
///
/// 写入时机：bootstrap step6（同步）+ 异步阶段 `switchBaseUrl`。
/// 默认 `''`（未就绪占位，design §E）。**UI 不 watch**（Property 21）。
@Riverpod(keepAlive: true)
class ApiEndpoint extends _$ApiEndpoint {
  @override
  String build() => '';

  // ignore: use_setters_to_change_properties
  void set(String endpoint) => state = endpoint;
}

/// 当前生效的订阅 endpoint（host）。写入时机同 [ApiEndpoint]。**UI 不 watch**（Property 21）。
@Riverpod(keepAlive: true)
class SubscriptionEndpoint extends _$SubscriptionEndpoint {
  @override
  String build() => '';

  // ignore: use_setters_to_change_properties
  void set(String endpoint) => state = endpoint;
}

/// SDK 单例（bootstrap step6 写 `XBoardSDK.instance`）。⚠️ 仅反腐层 read，UI 不碰。
///
/// 默认 `null`（未 initialize）；bootstrap 成功后写实例。
@Riverpod(keepAlive: true)
class XboardSdk extends _$XboardSdk {
  @override
  XBoardSDK? build() => null;

  // ignore: use_setters_to_change_properties
  void set(XBoardSDK sdk) => state = sdk;
}

/// SDK 是否已 initialize（DD-17 / F15）。
///
/// 同步阶段 fallback 兜底即 true；仅 fallback 损坏为 false（登录禁用 + banner）。
/// ✅ UI 可 watch（gate 登录入口 + 异常 banner）。
@Riverpod(keepAlive: true)
class BootstrapReady extends _$BootstrapReady {
  @override
  bool build() => false;

  // ignore: use_setters_to_change_properties
  void set(bool ready) => state = ready;
}

/// 是否首次进入 Xboard 模块（design §F / §J）。
///
/// bootstrap step0 检测「无 token + 无 `xb_consent_v1`」后写 true（一次性，不回退）。
/// ✅ UI 可 watch（合规 §F 首次离线检测 splash）。
@Riverpod(keepAlive: true)
class FirstLaunch extends _$FirstLaunch {
  @override
  bool build() => false;

  // ignore: use_setters_to_change_properties
  void set(bool value) => state = value;
}

/// 反腐层单例（conventions §2.1 / W2.2）。
///
/// 依赖 `xboardSdkProvider`（bootstrap step6 写 `XBoardSDK.instance`）；SDK 就绪后
/// 构造注入式 `XboardServiceImpl`（决策 #9）。bootstrap 完成前 SDK 为 null → 抛
/// StateError（UI 应先 gate `bootstrapReadyProvider`，不在未就绪时调反腐层）。
@Riverpod(keepAlive: true)
XboardService xboardService(Ref ref) {
  final sdk = ref.watch(xboardSdkProvider);
  if (sdk == null) {
    throw StateError(
      'XboardService 在 SDK initialize 前被访问 —— UI 应先 gate bootstrapReadyProvider',
    );
  }
  return XboardServiceImpl(sdk: sdk);
}
