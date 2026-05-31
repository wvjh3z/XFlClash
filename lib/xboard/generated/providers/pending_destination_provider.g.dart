// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../providers/pending_destination_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// pendingDestination 状态（keepAlive，跨登录页生命周期保留；登录成功消费后清 null）。
///
/// **UI 可 watch**：登录页 success 回调读取 + 清；路由守卫写入。

@ProviderFor(PendingDestinationNotifier)
final pendingDestinationProvider = PendingDestinationNotifierProvider._();

/// pendingDestination 状态（keepAlive，跨登录页生命周期保留；登录成功消费后清 null）。
///
/// **UI 可 watch**：登录页 success 回调读取 + 清；路由守卫写入。
final class PendingDestinationNotifierProvider
    extends $NotifierProvider<PendingDestinationNotifier, PendingDestination?> {
  /// pendingDestination 状态（keepAlive，跨登录页生命周期保留；登录成功消费后清 null）。
  ///
  /// **UI 可 watch**：登录页 success 回调读取 + 清；路由守卫写入。
  PendingDestinationNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'pendingDestinationProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$pendingDestinationNotifierHash();

  @$internal
  @override
  PendingDestinationNotifier create() => PendingDestinationNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(PendingDestination? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<PendingDestination?>(value),
    );
  }
}

String _$pendingDestinationNotifierHash() =>
    r'c7a81d2e07463f722fc3bd870fb3a05ea30dc369';

/// pendingDestination 状态（keepAlive，跨登录页生命周期保留；登录成功消费后清 null）。
///
/// **UI 可 watch**：登录页 success 回调读取 + 清；路由守卫写入。

abstract class _$PendingDestinationNotifier
    extends $Notifier<PendingDestination?> {
  PendingDestination? build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<PendingDestination?, PendingDestination?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<PendingDestination?, PendingDestination?>,
              PendingDestination?,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
