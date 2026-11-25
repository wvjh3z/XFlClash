/// 使用教程 provider（form-a 使用教程功能）。
///
/// **需登录**：知识库是 user 接口（带 token）；provider 仍独立检查认证状态。
/// **手写 provider**：调反腐层 `getTutorials()` / `getTutorialDetail(id)`，失败经 AsyncError 由 UI 分流。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_result.dart';
import '../models/xb_tutorial.dart';
import '../models/xb_domain_error.dart';
import '../sdk/xboard_service.dart';
import 'auth_state_provider.dart';
import 'catalog_read_cache.dart';
import 'xboard_providers.dart';
import 'user_profile_provider.dart';

/// Check the current subscription when presenting even a cached article.
final ipTutorialPlanAccessProvider = NotifierProvider.autoDispose<IpTutorialPlanAccess, bool>(IpTutorialPlanAccess.new);

class IpTutorialPlanAccess extends Notifier<bool> {
  @override
  bool build() {
    if (ref.watch(authStateProvider) != AuthState.authenticated) return false;
    final profile = ref.watch(userProfileProvider);
    final sub = profile.asData?.value;
    if (profile.isLoading || profile.hasError || sub == null ||
        !const {29, 30, 36}.contains(sub.planId)) {
      return false;
    }
    final expiry = sub.expiredAt;
    if (expiry == null) return true; // Xboard uses null for a non-expiring plan.
    final remaining = expiry.difference(DateTime.now());
    if (remaining <= Duration.zero) return false;
    final timer = Timer(remaining, () => state = false);
    ref.onDispose(timer.cancel);
    return true;
  }
}

/// 单次目录加载的总等待预算，含 SDK 重试与当前 service 恢复。
final tutorialListTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 20),
);

/// 使用教程列表（后端知识库「官方客户端」分类）。autoDispose：离页释放请求，成功数据最多复用24 小时。
///
/// 成功但空（该分类无文章）也是 data 态（非 error）——UI 据空列表显示空态。
/// SDK 已处理传输重试和客户端地址 failover；目录失败直接显示手动重试，
/// 避免 Riverpod 默认自动重试使缺失/禁用插件长期停留在加载态。
final tutorialsProvider = FutureProvider.autoDispose<List<XbTutorial>>((
  ref,
) async {
  if (ref.watch(authStateProvider) != AuthState.authenticated) {
    throw XbDomainError.unauthorized('请先登录');
  }
  final cache = ref.watch(catalogReadCacheProvider);
  final key = ('tutorials', ref.read(authStateProvider.notifier).sessionRevision);
  final cached = cache.lookup<List<XbTutorial>>(ref, key);
  if (cached != null) return cached;
  final service = ref.watch(xboardServiceProvider);
  final timeout = ref.watch(tutorialListTimeoutProvider);
  var active = true;
  ref.onDispose(() => active = false);
  try {
    final pending = service is XboardTutorialRequestControl
        ? (service as XboardTutorialRequestControl).getTutorialsForRequest(
            isActive: () => active,
          )
        : service.getTutorials();
    final result = await pending.timeout(
      timeout,
      onTimeout: () {
        active = false;
        throw XbDomainError.network(XbNetworkKind.timeout, '教程目录加载超时');
      },
    );
    return switch (result) {
      XbSuccess(:final data) => cache.remember<List<XbTutorial>>(ref, key, data),
      XbFailure(:final error) => throw error,
    };
  } finally {
    active = false;
  }
}, retry: (retryCount, error) => null);

/// 单篇教程详情（按文章 id）。family + autoDispose：按文章隔离24 小时成功缓存。
final tutorialDetailProvider = FutureProvider.autoDispose
    .family<XbTutorialDetail, int>((ref, id) async {
      if (ref.watch(authStateProvider) != AuthState.authenticated) {
        throw XbDomainError.unauthorized('请先登录');
      }
      final cache = ref.watch(catalogReadCacheProvider);
      final key = ('article', ref.read(authStateProvider.notifier).sessionRevision, id);
      final cached = cache.lookup<XbTutorialDetail>(ref, key);
      if (cached != null) return cached;
      final service = ref.watch(xboardServiceProvider);
      var active = true;
      ref.onDispose(() => active = false);
      try {
        final result = service is XboardTutorialRequestControl
            ? await (service as XboardTutorialRequestControl)
                  .getTutorialDetailForRequest(id, isActive: () => active)
            : await service.getTutorialDetail(id);
        return switch (result) {
          XbSuccess(:final data) => cache.remember<XbTutorialDetail>(ref, key, data),
          XbFailure(:final error) => throw error,
        };
      } finally {
        active = false;
      }
    }, retry: (retryCount, error) => null);
