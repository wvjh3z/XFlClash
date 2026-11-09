/// 生产端 [ProfileSyncPort] —— 调真实 FlClash `profilesActionProvider` + `Profile`（R7 / D62）。
///
/// **复用 FlClash 两步直接调用**（R7.5 / F225 / F226）：
/// - `Profile.normal(url, label).update()` 走 `_clashDio`（受 FlClashHttpOverrides 接管 + globalUa）。
/// - `profilesActionProvider.notifier.putProfile(profile)`（first-win 激活，F51/F226）。
/// - **禁止** `addProfileFormURL`（F225：内部 popUntil + toProfiles 破坏路由栈）。
///
/// **R4.1 文件化订阅**（`putFileProfile`）：SDK 自拉密文 → 解密 → 明文 YAML 字节经
/// 品牌暂存写入器复用 validateProfile 校验，再原子替换 `$id.yaml`，写 file 型
/// profile（url=''）；入库 → 设 currentProfileId → **仅在 initProvider==true 时** apply
/// （核心未就绪时靠 initStatus 的 force:true 自然加载）。
///
/// **错误形态**（R7.9 / F278）：`Profile.update()` 失败抛本地化中文字符串（非结构化异常），
/// 调用方（XboardSubscriptionService）catch 后归一为 XbSyncOutcome.failed。
library;

import 'dart:typed_data';

import 'package:fl_clash/common/path.dart' show appPath;
import 'package:fl_clash/database/database.dart'
    show Database, database, TableInfoExt, ProfilesCompanionExt;
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/core/method.dart'
    show CoreMethodException, isUnansweredCoreError;
import 'package:fl_clash/common/common.dart' show MessageException;
import 'package:fl_clash/providers/core.dart' show coreHandlerProvider;
import 'package:fl_clash/providers/database.dart' show profilesProvider;
import 'package:fl_clash/providers/config.dart' show currentProfileIdProvider;
import 'package:fl_clash/providers/app.dart' show initProvider;
import 'package:fl_clash/providers/state.dart' show isStartProvider;
import 'package:fl_clash/providers/action.dart'
    show profilesActionProvider, setupActionProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/profile_database_access.dart';
import 'profile_sync_port.dart';
import 'xb_profile_file_write.dart';
import 'sentry_bootstrap.dart';

class RiverpodProfileSyncPort implements ProfileSyncPort {
  RiverpodProfileSyncPort(
    this._ref, {
    Database? profileDatabase,
    Future<String> Function(int profileId)? profilePath,
    Future<Profile> Function(Profile profile, Uint8List bytes)? saveProfile,
  }) : _saveProfile = saveProfile,
       _database = profileDatabase ?? database,
       _profilePath =
           profilePath ?? ((id) => appPath.getProfilePath(id.toString()));

  final Future<Profile> Function(Profile, Uint8List)? _saveProfile;
  final Ref _ref;
  final Database _database;
  final Future<String> Function(int profileId) _profilePath;

  @override
  Future<int> createAndPutProfile({
    required String url,
    required String label,
  }) async {
    final profile = await Profile.normal(
      label: label,
      url: url,
    ).update(validate: _ref.read(coreHandlerProvider).validateProfile);
    _ref.read(profilesActionProvider.notifier).putProfile(profile);
    return profile.id;
  }

  @override
  Future<void> updateProfileUrl({
    required int profileId,
    required String url,
  }) async {
    final profiles = _ref.read(profilesProvider);
    final existing = profiles.where((p) => p.id == profileId).firstOrNull;
    if (existing == null) {
      // 索引指向的 profile 已不存在 → 当作新建（调用方会重写索引）。
      await createAndPutProfile(url: url, label: existing?.label ?? '我的套餐');
      return;
    }
    final updated = existing.copyWith(url: url);
    await _ref.read(profilesActionProvider.notifier).updateProfile(updated);
  }

  @override
  Future<int> putFileProfile({
    required int? profileId,
    required Uint8List yamlBytes,
    required String label,
    bool Function()? isSessionCurrent,
    Future<void> Function(int profileId)? beforeWrite,
    ProfileRecoveryOwner? recoveryOwner,
  }) async {
    bool sessionIsCurrent() =>
        _ref.mounted && isSessionCurrent?.call() != false;

    void ensureCurrent() {
      if (!sessionIsCurrent()) {
        throw const ProfileSyncCancelled();
      }
    }

    ensureCurrent();
    // File profile: validate staged bytes before atomic replacement; the core
    // reads the selected file and never fetches its subscription URL here.
    //
    // Validation and persistence may await; reject stale sessions before activation.
    // 内核校验超时语义由 D06 单独维护，不能由此推断配置一定经过完整有效校验。
    final profiles = _ref.read(profilesProvider);
    final existing = profileId == null
        ? null
        : profiles.where((p) => p.id == profileId).firstOrNull;

    final pending =
        existing?.copyWith(label: label) ??
        (profileId == null
            ? Profile.normal(label: label)
            : Profile.normal(label: label).copyWith(id: profileId));
    await beforeWrite?.call(pending.id);
    ensureCurrent();
    XbProfileFileWrite? write;
    try {
      final Profile saved;
      if (_saveProfile != null) {
        // Test-only legacy seam; production uses staged, validated replacement.
        saved = await _saveProfile(pending, yamlBytes);
      } else {
        write = await XbProfileFileWrite.create(
          targetPath: await _profilePath(pending.id),
          bytes: yamlBytes,
          ensureCurrent: ensureCurrent,
          recoveryOwner: recoveryOwner,
        );
        final String? message;
        try {
          message = await _ref
              .read(coreHandlerProvider)
              .validateProfile(write.candidate.path, pending.ageSecretKey);
        } catch (error) {
          ensureCurrent();
          if (isUnansweredCoreError(error) ||
              (error is CoreMethodException && error.isCoreUnavailable)) {
            throw ProfileValidationUnavailable(error);
          }
          rethrow;
        }
        ensureCurrent();
        if (message != null) throw MessageException(message);
        await write.publish();
        saved = pending.copyWith(lastUpdateDate: DateTime.now());
      }
      ensureCurrent();

      // Profiles.put 是乐观状态 + 异步数据库写入。这里等待已有公开 DB API 提交，
      // 才能在退出跨越提交时准确撤销；保留原标签去重规则，不改底座 schema/provider。
      final row = profiles.optimizeLabel(saved).toCompanion();
      try {
        await retryProfileDatabaseWrite(
          () => _database.profiles.put(row),
          ensureCurrent: ensureCurrent,
        );
      } on ProfileSyncCancelled {
        // Cancellation between busy attempts must not leave an old-session file.
        await _deleteFile(saved.id);
        rethrow;
      }
      if (!sessionIsCurrent()) {
        await deleteProfile(saved.id, recoveryOwner: recoveryOwner);
        throw const ProfileSyncCancelled();
      }
      // File and row now agree. Later activation failures must not roll the
      // file back underneath the committed row. Session cleanup still owns both.
      write?.commit();
      _ref.invalidate(profilesProvider);
      if (!sessionIsCurrent()) {
        await deleteProfile(saved.id, recoveryOwner: recoveryOwner);
        throw const ProfileSyncCancelled();
      }

      // Validation is complete. Existing initialization/application policy is
      // retained; transient validation failures are recovered by the service.
      _ref.read(currentProfileIdProvider.notifier).value = saved.id;
      if (_ref.read(initProvider)) {
        _ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
      // else: 核心未就绪 → 不触发 setup。initStatus 会在核心 ready 后用 force:true 加载。
      if (recoveryOwner != null) {
        await XbProfileFileWrite.cleanupOwned(
          targetPath: await _profilePath(saved.id),
          owner: recoveryOwner,
          excludeDirectory: write?.directory.path,
          diagnostics: _recoveryDiagnostics,
          ensureCurrent: ensureCurrent,
        );
      }
      return saved.id;
    } catch (error, stack) {
      if (!sessionIsCurrent()) {
        write?.abandonForSessionEnd();
        await deleteProfile(pending.id, recoveryOwner: recoveryOwner);
        throw const ProfileSyncCancelled();
      }
      try {
        await write?.rollback();
      } catch (recoveryError, recoveryStack) {
        SentryBootstrap.captureException(
          recoveryError,
          stackTrace: recoveryStack,
          where: 'subscription profile recovery; backup retained',
        );
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      final cleanupError = await write?.cleanup();
      if (cleanupError != null) {
        SentryBootstrap.captureException(
          cleanupError,
          where: 'subscription temporary file cleanup',
        );
      }
    }
  }

  static final _recoveryDiagnostics = ProfileRecoveryDiagnostics((warning) {
    SentryBootstrap.captureFromSdk(
      'warning',
      'Subscription recovery material retained: ${warning.name}',
    );
  });

  final _deactivations = <int, Future<void>>{};

  @override
  Future<void> deactivateProfile(int profileId) => _deactivations.putIfAbsent(
    profileId,
    () => _deactivateProfile(profileId).whenComplete(() {
      _deactivations.removeWhere((id, _) => id == profileId);
    }),
  );

  Future<void> _deactivateProfile(int profileId) async {
    // 仅停用当前正被使用的账号 Profile；选中的手工/其他账号 Profile 不应被误断。
    if (_ref.mounted && _ref.read(currentProfileIdProvider) == profileId) {
      if (_ref.read(isStartProvider)) {
        await _ref.read(setupActionProvider.notifier).setRunning(false);
      }
      // 停止期间用户可能切换 Profile，再确认选择态才清掉旧选择。
      if (_ref.mounted && _ref.read(currentProfileIdProvider) == profileId) {
        _ref.read(currentProfileIdProvider.notifier).value = null;
      }
    }
  }

  @override
  Future<void> deleteProfile(
    int profileId, {
    ProfileRecoveryOwner? recoveryOwner,
  }) async {
    await deactivateProfile(profileId);
    // 明文文件和 DB 任一步失败都抛出，服务保留外挂索引以供恢复，不能假报清理成功。
    await _deleteFile(profileId);
    if (recoveryOwner != null) {
      await XbProfileFileWrite.cleanupOwned(
        targetPath: await _profilePath(profileId),
        owner: recoveryOwner,
        diagnostics: _recoveryDiagnostics,
      );
    }
    await _database.profiles.remove((t) => t.id.equals(profileId));
    // 旧订阅服务可能已被认证编排 dispose。补偿删除仍完成持久化，不能再触碰其 Ref。
    if (_ref.mounted) _ref.invalidate(profilesProvider);
  }

  Future<void> _deleteFile(int profileId) async {
    final path = await _profilePath(profileId);
    await XbProfileFileWrite.removeFileIfPresent(path);
  }

  @override
  List<int> currentProfileIds() =>
      _ref.read(profilesProvider).map((p) => p.id).toList();
}
