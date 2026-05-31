// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../providers/auth_state_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 登录态 provider（keepAlive，DD-19）。
///
/// **W3.2 不在 W1.6 基础设施集**：单独建避免 codegen 同名冲突（design §I 注）。

@ProviderFor(AuthStateNotifier)
final authStateProvider = AuthStateNotifierProvider._();

/// 登录态 provider（keepAlive，DD-19）。
///
/// **W3.2 不在 W1.6 基础设施集**：单独建避免 codegen 同名冲突（design §I 注）。
final class AuthStateNotifierProvider
    extends $NotifierProvider<AuthStateNotifier, AuthState> {
  /// 登录态 provider（keepAlive，DD-19）。
  ///
  /// **W3.2 不在 W1.6 基础设施集**：单独建避免 codegen 同名冲突（design §I 注）。
  AuthStateNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'authStateProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$authStateNotifierHash();

  @$internal
  @override
  AuthStateNotifier create() => AuthStateNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AuthState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AuthState>(value),
    );
  }
}

String _$authStateNotifierHash() => r'35bb9ef0b6b345b7e1ba35bb44fb7aa2387931dc';

/// 登录态 provider（keepAlive，DD-19）。
///
/// **W3.2 不在 W1.6 基础设施集**：单独建避免 codegen 同名冲突（design §I 注）。

abstract class _$AuthStateNotifier extends $Notifier<AuthState> {
  AuthState build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<AuthState, AuthState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AuthState, AuthState>,
              AuthState,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
