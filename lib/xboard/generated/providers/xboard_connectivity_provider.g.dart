// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../providers/xboard_connectivity_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 网络连接状态流（首帧 `checkConnectivity()` 当前值 + 后续 `onConnectivityChanged`）。
///
/// keepAlive：与 App 同寿（连接状态全局共享，避免每个 widget 各自订阅）。

@ProviderFor(xboardConnectivity)
final xboardConnectivityProvider = XboardConnectivityProvider._();

/// 网络连接状态流（首帧 `checkConnectivity()` 当前值 + 后续 `onConnectivityChanged`）。
///
/// keepAlive：与 App 同寿（连接状态全局共享，避免每个 widget 各自订阅）。

final class XboardConnectivityProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ConnectivityResult>>,
          List<ConnectivityResult>,
          Stream<List<ConnectivityResult>>
        >
    with
        $FutureModifier<List<ConnectivityResult>>,
        $StreamProvider<List<ConnectivityResult>> {
  /// 网络连接状态流（首帧 `checkConnectivity()` 当前值 + 后续 `onConnectivityChanged`）。
  ///
  /// keepAlive：与 App 同寿（连接状态全局共享，避免每个 widget 各自订阅）。
  XboardConnectivityProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'xboardConnectivityProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$xboardConnectivityHash();

  @$internal
  @override
  $StreamProviderElement<List<ConnectivityResult>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<ConnectivityResult>> create(Ref ref) {
    return xboardConnectivity(ref);
  }
}

String _$xboardConnectivityHash() =>
    r'11ec2d1a815bc42e5489722a3435b1d2b12b46f7';

/// 是否离线（派生）—— `none` 在结果集中即视为离线（ζ9 跨平台一致）。
///
/// 未就绪 / 错误时**不**判离线（保守：避免误弹离线页），返 false。

@ProviderFor(isOffline)
final isOfflineProvider = IsOfflineProvider._();

/// 是否离线（派生）—— `none` 在结果集中即视为离线（ζ9 跨平台一致）。
///
/// 未就绪 / 错误时**不**判离线（保守：避免误弹离线页），返 false。

final class IsOfflineProvider extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  /// 是否离线（派生）—— `none` 在结果集中即视为离线（ζ9 跨平台一致）。
  ///
  /// 未就绪 / 错误时**不**判离线（保守：避免误弹离线页），返 false。
  IsOfflineProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'isOfflineProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$isOfflineHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return isOffline(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$isOfflineHash() => r'0007ad5c61baf67bbaf866990aeb957c981c250e';
