/// 分享落地页地址 provider（form-a 分享好友 + 邀请返佣页共用）。
///
/// **免登录**：ShareLink 是 guest 接口，游客态也可调（SDK 已 initialize 即可，无需 token）。
/// **手写 provider**：调反腐层 `getShareLink()`，永不抛——失败经 AsyncError 由 UI 分流。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_invite.dart';
import '../models/xb_result.dart';
import 'xboard_providers.dart';
import 'catalog_read_cache.dart';
import 'invite_provider.dart' show commissionSessionProvider;

class ShareServicePreparing implements Exception {
  const ShareServicePreparing();
}
/// 分享落地页地址（主/备）。autoDispose：页面离开释放请求，成功地址最多复用五分钟。
///
/// 成功且 `enabled=false`（后台关闭/未配置）也是 data 态（非 error）——UI 据 enabled 显示未配置态。
final shareLinkProvider = FutureProvider.autoDispose<XbShareLink>((ref) async {
  ref.watch(commissionSessionProvider);
  if (!ref.watch(bootstrapReadyProvider) && ref.watch(xboardSdkProvider) == null) {
    throw const ShareServicePreparing();
  }
  final cache = ref.watch(catalogReadCacheProvider);
  final key = ('public-share-addresses', ref.watch(apiEndpointProvider));
  final cached = cache.lookup<XbShareLink>(ref, key);
  if (cached != null) return cached;
  final result = await ref.watch(xboardServiceProvider).getShareLink();
  return switch (result) {
    XbSuccess(:final data) => cache.remember<XbShareLink>(ref, key, data, ttl: CatalogReadCache.shareLinkTtl),
    XbFailure(:final error) => throw error,
  };
}, retry: (retryCount, error) => null);
