// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../providers/user_profile_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 账号订阅信息（R6）。success → 数据；failure → 抛 XbDomainError（UI 经 AsyncValue.error
/// 用 XboardStateView 分流，error 态按 7 子类型渲染）。
///
/// keepAlive：登录态期间常驻；logout / 切账号时调用方 `ref.invalidate` 清。

@ProviderFor(userProfile)
final userProfileProvider = UserProfileProvider._();

/// 账号订阅信息（R6）。success → 数据；failure → 抛 XbDomainError（UI 经 AsyncValue.error
/// 用 XboardStateView 分流，error 态按 7 子类型渲染）。
///
/// keepAlive：登录态期间常驻；logout / 切账号时调用方 `ref.invalidate` 清。

final class UserProfileProvider
    extends
        $FunctionalProvider<
          AsyncValue<XbDomainSubscription>,
          XbDomainSubscription,
          FutureOr<XbDomainSubscription>
        >
    with
        $FutureModifier<XbDomainSubscription>,
        $FutureProvider<XbDomainSubscription> {
  /// 账号订阅信息（R6）。success → 数据；failure → 抛 XbDomainError（UI 经 AsyncValue.error
  /// 用 XboardStateView 分流，error 态按 7 子类型渲染）。
  ///
  /// keepAlive：登录态期间常驻；logout / 切账号时调用方 `ref.invalidate` 清。
  UserProfileProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'userProfileProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$userProfileHash();

  @$internal
  @override
  $FutureProviderElement<XbDomainSubscription> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<XbDomainSubscription> create(Ref ref) {
    return userProfile(ref);
  }
}

String _$userProfileHash() => r'cd35a027d09ce59bbb1ebab3bf0e94fdd81c913f';
