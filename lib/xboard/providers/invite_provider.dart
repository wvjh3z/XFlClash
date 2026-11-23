/// 邀请返佣 providers（form-a 邀请功能）。
///
/// **手写 provider**（与 codegen provider 共存）：调反腐层 `XboardService`，永不抛——
/// 失败经 `AsyncValue.error(XbDomainError)` 由 UI 的 [XbAsyncView] 分流（error 态重试）。
///
/// **gate**：调用方页面须在已登录态进入（邀请功能需 token）；`xboardServiceProvider` 在 SDK
/// 未就绪时抛 StateError（UI 应先 gate bootstrapReady + authenticated）。
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/xb_invite.dart';
import '../models/xb_domain_error.dart';
import '../models/xb_result.dart';
import '../sdk/xboard_service.dart';
import 'auth_state_provider.dart';
import 'xboard_providers.dart';

// Session lifetime, not dialog lifetime. No account details, payout accounts or
// credentials are held here. A late result can only mutate its original ledger.
class _LedgerCache {
  CommissionSession? value;
}
final _ledgerCache = Provider((ref) => _LedgerCache());
final commissionSessionProvider = Provider<CommissionSession>((ref) {
  ref.watch(authStateProvider);
  final revision = ref.read(authStateProvider.notifier).sessionRevision;
  final cache = ref.read(_ledgerCache);
  final previous = cache.value;
  if (previous != null && previous.revision == revision) return previous;
  return cache.value = CommissionSession(revision);
});

class CommissionSession {
  CommissionSession(this.revision);
  final int revision;
  bool allowCodeGeneration = true;
  bool codeUnconfirmed = false;
  Completer<void>? _exclusive;
  Completer<void>? _readersDone;
  int _readers = 0;
  bool get busy => _exclusive != null;
  Future<void> get readersDone => _readersDone?.future ?? Future<void>.value();
  void release() {
    final lock = _exclusive;
    _exclusive = null;
    lock?.complete();
  }
  Future<T> backgroundRead<T>(Future<T> Function() load) async {
    while (_exclusive != null) {
      await _exclusive!.future;
    }
    _readers++;
    _readersDone ??= Completer<void>();
    try {
      return await load();
    } finally {
      if (--_readers == 0) {
        final done = _readersDone;
        _readersDone = null;
        done?.complete();
      }
    }
  }
  String? pendingOperation;
  int? pendingCents;

  bool acquire({bool reconciliation = false}) {
    if (busy || (!reconciliation && pendingOperation != null)) return false;
    _exclusive = Completer<void>();
    return true;
  }

  void markUnknown(String operation, int cents) {
    pendingOperation = operation;
    pendingCents = cents;
  }
}

// A cancelled/failed transport after invoking a write is not proof the server
// rejected it (including a stale service returning a cancellation).
bool commissionWriteNeedsReview(XbResult<bool> result) => switch (result) {
  XbSuccess(:final data) => !data,
  XbFailure(:final error) => error is XbUnconfirmed || error is XbNetwork ||
      error is XbServer || error is XbUnexpected,
};

final commissionReadOwnerProvider = Provider((ref) {
  final session = ref.watch(commissionSessionProvider);
  XboardService? service;
  try {
    service = ref.watch(xboardServiceProvider);
  } catch (_) {
    // SDK not installed yet. A bootstrap dependency change rebuilds this key.
  }
  return (session, service);
});

/// 邀请返佣汇总（autoDispose：进页拉、离页回收，下拉刷新用 invalidate）。
///
/// **无邀请码自动生成**（原型决策）：首拉若 `!hasCode`，自动调 `generateInviteCode()` 后重拉一次；
/// 生成失败不阻塞（沿用无码态，UI 仍可展示统计 / 引导）。
final inviteInfoProvider = FutureProvider.autoDispose<XbInviteInfo>((
  ref,
) async {
  final service = ref.watch(xboardServiceProvider);
  final session = ref.watch(commissionSessionProvider);
  final mayCreate = session.allowCodeGeneration && !session.codeUnconfirmed;
  session.allowCodeGeneration = false;
  var active = true;
  ref.onDispose(() => active = false);
  Future<XbInviteInfo> load() async {
    if (!active) throw const XbNetwork(XbNetworkKind.cancelled, '页面已关闭');
    final result = await service.getInviteInfo();
    if (!active && mayCreate) session.allowCodeGeneration = true;
    var info = switch (result) {
      XbSuccess(:final data) => data,
      XbFailure(:final error) => throw error,
    };
    if (!active) return info;
    if (!info.hasCode && mayCreate && !session.busy && session.pendingOperation == null) {
      XbResult<String> gen;
      try {
        gen = await service.generateInviteCode();
      } catch (_) {
        session.codeUnconfirmed = true;
        return info;
      }
      if (!active) {
        // A queued write can have been cancelled, or dispatched. Only a
        // subsequent read can distinguish an already-created code.
        if (gen case XbFailure(error: XbUnconfirmed())) {
          session.codeUnconfirmed = true;
        }
        if (gen case XbFailure(error: XbNetwork(kind: XbNetworkKind.cancelled))) {
          session.allowCodeGeneration = true;
        }
        return info;
      }
      if (gen is XbSuccess<String>) {
        try {
          final reload = await service.getInviteInfo();
          if (active && reload is XbSuccess<XbInviteInfo>) info = reload.data;
        } catch (_) {
          // Generation succeeded. Show the valid stats, retry by reading only.
        }
        session.codeUnconfirmed = !info.hasCode;
      } else if (gen case XbFailure(error: XbUnconfirmed())) {
        session.codeUnconfirmed = true;
      }
    }
    return info;
  }

  try {
    return await session.backgroundRead(() => service is XboardInviteRequestControl
        ? (service as XboardInviteRequestControl).withInviteRequestValidity(
            () => active,
            load,
          )
        : load());
  } finally {
    active = false;
  }
}, retry: (retryCount, error) => null);

const commissionRecordsPageSize = 50;

/// 邀请页入口与流水页共享首页，不将满页的条数当作总数。
final commissionRecordsProvider =
    FutureProvider.autoDispose<List<XbCommissionRecord>>((ref) async {
      final session = ref.watch(commissionSessionProvider);
      final service = ref.watch(xboardServiceProvider);
      final result = await session.backgroundRead(() {
        if (!ref.mounted) throw const XbNetwork(XbNetworkKind.cancelled, '页面已关闭');
        return service.getCommissionRecords(pageSize: commissionRecordsPageSize);
      });
      return switch (result) {
        XbSuccess(:final data) => data,
        XbFailure(:final error) => throw error,
      };
    }, retry: (retryCount, error) => null);

/// 提现收款方式白名单（后端 `/api/v1/user/comm/config`）。
///
/// autoDispose：随提现弹窗所在页进/离。失败或空 → 返空列表（**不抛**），UI 侧回退到本地默认
/// 白名单 `kWithdrawMethods`（提现弹窗只在已配置时才更有意义，但接口不可用不应阻断提现入口）。
final withdrawConfigProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final result = await ref.watch(xboardServiceProvider).getWithdrawMethods();
  return switch (result) {
    XbSuccess(:final data) => data,
    XbFailure() => const <String>[],
  };
}, retry: (retryCount, error) => null);

/// 同步暴露收款方式列表给提现弹窗（未就绪 / 失败 → 空，UI 回退 `kWithdrawMethods`）。
///
/// 拆出同步 `Provider` 是为让弹窗的 `_methods` getter 直接拿 `List<String>`（无需在 getter 里处理
/// AsyncValue），保持下拉构建简单；底层异步拉取仍由 [withdrawConfigProvider] 负责。
final withdrawMethodsProvider = Provider.autoDispose<List<String>>((ref) {
  return ref.watch(withdrawConfigProvider).asData?.value ?? const <String>[];
});
