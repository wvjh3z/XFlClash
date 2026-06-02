/// FlClash profile 操作的反腐层端口（R7 / D62 / conventions §2.1）。
///
/// **为什么有这层**：R7 必须复用 FlClash `Profile.update()` + `profilesActionProvider`
/// （禁止 SDK dio 自拉订阅，否则占满 IpAuth max_ip_count=2，D62/F80）。直接在 service 里
/// 调 FlClash provider 会让 R7 逻辑无法单测（依赖 FlClash 运行时）。抽出端口接口，生产端
/// 用 `RiverpodProfileSyncPort` 调真实 FlClash provider，测试端注入 fake。
library;

import 'dart:typed_data';

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
  Future<int> putFileProfile({
    required int? profileId,
    required Uint8List yamlBytes,
    required String label,
  });

  /// 删除 profile（退出登录，R7.12 → `Profiles.del`）。
  Future<void> deleteProfile(int profileId);

  /// 当前 FlClash 所有 profile id（孤儿对账用，§C）。
  List<int> currentProfileIds();
}
