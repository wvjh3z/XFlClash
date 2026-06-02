/// 生产端 [ProfileSyncPort] —— 调真实 FlClash `profilesActionProvider` + `Profile`（R7 / D62）。
///
/// **复用 FlClash 两步直接调用**（R7.5 / F225 / F226）：
/// - `Profile.normal(url, label).update()` 走 `_clashDio`（受 FlClashHttpOverrides 接管 + globalUa）。
/// - `profilesActionProvider.notifier.putProfile(profile)`（first-win 激活，F51/F226）。
/// - **禁止** `addProfileFormURL`（F225：内部 popUntil + toProfiles 破坏路由栈）。
///
/// **R4.1 文件化订阅**（`putFileProfile`）：SDK 自拉密文 → 解密 → 明文 YAML 字节经
/// `Profile.saveFile(bytes)`（现成公开方法：validateConfig 校验 + 写 `$id.yaml`）写 file 型
/// profile（url=''）；新建走 putProfile first-win，覆写走 setProfileAndAutoApply（active 时
/// applyProfileDebounce 通知 core 重载）。**零改上游**——saveFile/setProfileAndAutoApply 均现成。
///
/// **错误形态**（R7.9 / F278）：`Profile.update()` 失败抛本地化中文字符串（非结构化异常），
/// 调用方（XboardSubscriptionService）catch 后归一为 XbSyncOutcome.failed。
library;

import 'dart:typed_data';

import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/database.dart' show profilesProvider;
import 'package:fl_clash/providers/config.dart' show currentProfileIdProvider;
import 'package:fl_clash/providers/action.dart' show profilesActionProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'profile_sync_port.dart';

class RiverpodProfileSyncPort implements ProfileSyncPort {
  RiverpodProfileSyncPort(this._ref);

  final Ref _ref;

  @override
  Future<int> createAndPutProfile(
      {required String url, required String label}) async {
    final profile = await Profile.normal(label: label, url: url).update();
    _ref.read(profilesActionProvider.notifier).putProfile(profile);
    return profile.id;
  }

  @override
  Future<void> updateProfileUrl(
      {required int profileId, required String url}) async {
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
  }) async {
    // file 型 profile：url 留空（ProfileType.file），明文 bytes 经 saveFile（validateConfig +
    // 写 $id.yaml）。core 从文件路径加载，不重拉 url（R4.5 查证）。
    final profiles = _ref.read(profilesProvider);
    final existing =
        profileId == null ? null : profiles.where((p) => p.id == profileId).firstOrNull;

    if (existing != null) {
      // 原地覆写：保留 id + 选择态，写新明文文件 → 若是当前 active 则 applyProfileDebounce 重载。
      final saved = await existing.copyWith(label: label).saveFile(yamlBytes);
      _ref.read(profilesActionProvider.notifier).setProfileAndAutoApply(saved);
      return saved.id;
    }

    // 新建 file 型 profile（url=''）→ saveFile → putProfile first-win 激活。
    final profile = await Profile.normal(label: label).saveFile(yamlBytes);
    _ref.read(profilesActionProvider.notifier).putProfile(profile);
    return profile.id;
  }

  @override
  Future<void> deleteProfile(int profileId) async {
    // FlClash Profiles 删除经 profilesProvider.notifier（Profiles.del(int)）。
    _ref.read(profilesProvider.notifier).del(profileId);
    if (_ref.read(currentProfileIdProvider) == profileId) {
      _ref.read(currentProfileIdProvider.notifier).value = null;
    }
  }

  @override
  List<int> currentProfileIds() =>
      _ref.read(profilesProvider).map((p) => p.id).toList();
}
