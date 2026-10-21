/// 生产端 [ProfileSyncPort] —— 调真实 FlClash `profilesActionProvider` + `Profile`（R7 / D62）。
///
/// **复用 FlClash 两步直接调用**（R7.5 / F225 / F226）：
/// - `Profile.normal(url, label).update()` 走 `_clashDio`（受 FlClashHttpOverrides 接管 + globalUa）。
/// - `profilesActionProvider.notifier.putProfile(profile)`（first-win 激活，F51/F226）。
/// - **禁止** `addProfileFormURL`（F225：内部 popUntil + toProfiles 破坏路由栈）。
///
/// **R4.1 文件化订阅**（`putFileProfile`）：SDK 自拉密文 → 解密 → 明文 YAML 字节经
/// `Profile.saveFile(bytes)`（现成公开方法：validateConfig 校验 + 写 `$id.yaml`）写 file 型
/// profile（url=''）；入库 → 设 currentProfileId → **仅在 initProvider==true 时** apply
/// （核心未就绪时靠 initStatus 的 force:true 自然加载）。
///
/// **错误形态**（R7.9 / F278）：`Profile.update()` 失败抛本地化中文字符串（非结构化异常），
/// 调用方（XboardSubscriptionService）catch 后归一为 XbSyncOutcome.failed。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/path.dart' show appPath;
import 'package:fl_clash/database/database.dart'
    show Database, database, TableInfoExt, ProfilesCompanionExt;
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/database.dart' show profilesProvider;
import 'package:fl_clash/providers/config.dart' show currentProfileIdProvider;
import 'package:fl_clash/providers/app.dart' show initProvider;
import 'package:fl_clash/providers/state.dart' show isStartProvider;
import 'package:fl_clash/providers/action.dart'
    show profilesActionProvider, setupActionProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/profile_database_access.dart';
import 'profile_sync_port.dart';

class RiverpodProfileSyncPort implements ProfileSyncPort {
  RiverpodProfileSyncPort(
    this._ref, {
    Database? profileDatabase,
    Future<String> Function(int profileId)? profilePath,
    Future<Profile> Function(Profile profile, Uint8List bytes)? saveProfile,
  }) : _saveProfile =
           saveProfile ?? ((profile, bytes) => profile.saveFile(bytes)),
       _database = profileDatabase ?? database,
       _profilePath =
           profilePath ?? ((id) => appPath.getProfilePath(id.toString()));

  final Future<Profile> Function(Profile, Uint8List) _saveProfile;
  final Ref _ref;
  final Database _database;
  final Future<String> Function(int profileId) _profilePath;

  @override
  Future<int> createAndPutProfile({
    required String url,
    required String label,
  }) async {
    final profile = await Profile.normal(label: label, url: url).update();
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
  }) async {
    bool sessionIsCurrent() =>
        _ref.mounted && isSessionCurrent?.call() != false;

    void ensureCurrent() {
      if (!sessionIsCurrent()) {
        throw const ProfileSyncCancelled();
      }
    }

    ensureCurrent();
    // file 型 profile：url 留空（ProfileType.file），明文 bytes 经 saveFile（validateConfig +
    // 写 $id.yaml）。core 从文件路径加载，不重拉 url（R4.5 查证）。
    //
    // saveFile 内部校验和写盘可能耗时；会话结束后必须在提交/激活之前拒绝晚到结果。
    // 内核校验超时语义由 D06 单独维护，不能由此推断配置一定经过完整有效校验。
    final profiles = _ref.read(profilesProvider);
    final existing = profileId == null
        ? null
        : profiles.where((p) => p.id == profileId).firstOrNull;

    final pending =
        existing?.copyWith(label: label) ?? Profile.normal(label: label);
    final saved = await _saveProfile(pending, yamlBytes);
    if (!sessionIsCurrent()) {
      // saveFile 的校验可能跨越会话退出；只删本次旧归属 ID 的文件，不激活它。
      await _deleteFile(saved.id);
      throw const ProfileSyncCancelled();
    }

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
      await deleteProfile(saved.id);
      throw const ProfileSyncCancelled();
    }
    _ref.invalidate(profilesProvider);
    if (!sessionIsCurrent()) {
      await deleteProfile(saved.id);
      throw const ProfileSyncCancelled();
    }

    // 🔴 强制激活 + 时序安全（2026-06-04 二修）：
    // 问题：`applyProfileDebounce` 触发的 setup 流程中 `getConfig` 需要 Go 核心响应。冷启动
    // 早期核心 IPC 未连接时，`getConfig` 的 `_invoke` 10 秒超时返回 null → 上层把 null 当
    // "空配置成功" → 写出空 config.yaml → 代理页 0 节点。
    //
    // 修复：
    // 1. **立即**设 currentProfileId 指向本 profile（保证 FlClash 知道该用哪个 profile）。
    // 2. 只在 `initProvider == true`（核心已连接 + 就绪）时才主动 `applyProfileDebounce`。
    // 3. 若核心未就绪，**不主动 apply**——`_initApp` 末尾的 `initStatus` 会在核心 ready 后
    //    自然触发 `applyProfile(force:true)` 加载当前 profile（此时我们已设好 currentProfileId）。
    //
    // 效果：文件照常写（saveFile 内部 validateConfig 本身会等核心），profile 入库 + 设 current
    // 都不受核心影响；只有真正的 setup（需要 getConfig 完整解析）才等核心 ready 后跑。
    _ref.read(currentProfileIdProvider.notifier).value = saved.id;
    if (_ref.read(initProvider)) {
      _ref
          .read(setupActionProvider.notifier)
          .applyProfileDebounce(silence: true);
    }
    // else: 核心未就绪 → 不触发 setup。initStatus 会在核心 ready 后用 force:true 加载。
    return saved.id;
  }

  @override
  Future<void> deleteProfile(int profileId) async {
    // 仅停用当前正被使用的账号 Profile；选中的手工/其他账号 Profile 不应被误断。
    if (_ref.mounted && _ref.read(currentProfileIdProvider) == profileId) {
      if (_ref.read(isStartProvider)) {
        await _ref.read(setupActionProvider.notifier).updateStatus(false);
      }
      // 停止期间用户可能切换 Profile，再确认选择态才清掉旧选择。
      if (_ref.mounted && _ref.read(currentProfileIdProvider) == profileId) {
        _ref.read(currentProfileIdProvider.notifier).value = null;
      }
    }
    // 明文文件和 DB 任一步失败都抛出，服务保留外挂索引以供恢复，不能假报清理成功。
    await _deleteFile(profileId);
    await _database.profiles.remove((t) => t.id.equals(profileId));
    // 旧订阅服务可能已被认证编排 dispose。补偿删除仍完成持久化，不能再触碰其 Ref。
    if (_ref.mounted) _ref.invalidate(profilesProvider);
  }

  Future<void> _deleteFile(int profileId) async {
    final path = await _profilePath(profileId);
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  List<int> currentProfileIds() =>
      _ref.read(profilesProvider).map((p) => p.id).toList();
}
