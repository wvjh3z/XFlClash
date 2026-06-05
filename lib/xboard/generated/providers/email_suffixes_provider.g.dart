// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../providers/email_suffixes_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 邮箱注册白名单后缀列表（R5.6）。
///
/// 成功 → 后缀列表（可空 = 白名单禁用）；失败 → `const []`（fail-open，不阻塞注册）。

@ProviderFor(emailSuffixes)
final emailSuffixesProvider = EmailSuffixesProvider._();

/// 邮箱注册白名单后缀列表（R5.6）。
///
/// 成功 → 后缀列表（可空 = 白名单禁用）；失败 → `const []`（fail-open，不阻塞注册）。

final class EmailSuffixesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<String>>,
          List<String>,
          FutureOr<List<String>>
        >
    with $FutureModifier<List<String>>, $FutureProvider<List<String>> {
  /// 邮箱注册白名单后缀列表（R5.6）。
  ///
  /// 成功 → 后缀列表（可空 = 白名单禁用）；失败 → `const []`（fail-open，不阻塞注册）。
  EmailSuffixesProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'emailSuffixesProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$emailSuffixesHash();

  @$internal
  @override
  $FutureProviderElement<List<String>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<String>> create(Ref ref) {
    return emailSuffixes(ref);
  }
}

String _$emailSuffixesHash() => r'69a82ee1e21362ab564a7104d1742615e31fc6c7';
