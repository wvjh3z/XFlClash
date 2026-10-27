/// FlClash profile 操作的反腐层端口（R7 / D62 / conventions §2.1）。
///
/// 文件化订阅通过现有 Profile.saveFile 校验和落盘；直接在 service 中调用底座会让
/// 业务无法单测。生产端用 RiverpodProfileSyncPort，测试端注入 fake。
library;

import 'dart:typed_data';

/// 请求所属会话已经结束，端口不再提交或激活它的 Profile。
class ProfileSyncCancelled implements Exception {
  const ProfileSyncCancelled();
}

/// profile 同步端口（封装 FlClash Profile.update / putProfile / updateProfile / del）。
abstract interface class ProfileSyncPort {
  /// 用订阅 URL 新建并拉取 profile（`Profile.normal(url).update()` + putProfile first-win）。
  /// 返回新 profile 的 id（FlClash Profile.id，int snowflake）。
  Future<int> createAndPutProfile({required String url, required String label});

  /// 更新已存在 profile 的 url 并重新拉取（endpoint 切换 / 主动刷新走此）。
  Future<void> updateProfileUrl({required int profileId, required String url});

  /// R4.1 文件化订阅：用**已解密的明文 ClashMeta YAML 字节**写本地文件 profile（file 型，
  /// url 为空），校验通过后激活 + 通知 core 重载。SDK 自拉密文 → 解密 → 走此写文件（绕过
  /// `Profile.update` 的 URL 拉取，FlClash 只认明文文件）。
  ///
  /// [profileId]：已存在则原地覆写（保留 id，core 重载），null 则新建。
  /// 返回写入的 profile id。validateConfig 失败抛中文字符串异常（同 saveFile，调用方 catch）。
  /// [beforeWrite] durably reserves the chosen ID before any file/main DB side effect.
  /// Missing main rows reuse a supplied ID so retries keep their ownership evidence.
  /// [isSessionCurrent] 在异步校验/写盘之后、提交和激活之前重新校验会话；失效时清理
  /// 该次写出的旧账号文件并抛 [ProfileSyncCancelled]，不能激活晚到订阅。
  Future<int> putFileProfile({
    required int? profileId,
    required Uint8List yamlBytes,
    required String label,
    bool Function()? isSessionCurrent,
    Future<void> Function(int profileId)? beforeWrite,
  });

  /// Stop using an owned Profile without racing its in-flight file write.
  Future<void> deactivateProfile(int profileId);

  /// 删除旧账号 Profile 的持久记录和明文文件；正在使用该 Profile 时先停用。
  /// 删除失败必须抛出，调用方保留索引作为恢复线索；手动/其他账号 Profile 不受影响。
  Future<void> deleteProfile(int profileId);

  /// 当前 FlClash 所有 profile id（孤儿对账用，§C）。
  List<int> currentProfileIds();
}
