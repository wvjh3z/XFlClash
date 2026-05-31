/// FlClash profile 操作的反腐层端口（R7 / D62 / conventions §2.1）。
///
/// **为什么有这层**：R7 必须复用 FlClash `Profile.update()` + `profilesActionProvider`
/// （禁止 SDK dio 自拉订阅，否则占满 IpAuth max_ip_count=2，D62/F80）。直接在 service 里
/// 调 FlClash provider 会让 R7 逻辑无法单测（依赖 FlClash 运行时）。抽出端口接口，生产端
/// 用 `RiverpodProfileSyncPort` 调真实 FlClash provider，测试端注入 fake。
library;

/// profile 同步端口（封装 FlClash Profile.update / putProfile / updateProfile / del）。
abstract interface class ProfileSyncPort {
  /// 用订阅 URL 新建并拉取 profile（`Profile.normal(url).update()` + putProfile first-win）。
  /// 返回新 profile 的 id（FlClash Profile.id，int snowflake）。
  Future<int> createAndPutProfile({required String url, required String label});

  /// 更新已存在 profile 的 url 并重新拉取（endpoint 切换 / 主动刷新走此）。
  Future<void> updateProfileUrl({required int profileId, required String url});

  /// 删除 profile（退出登录，R7.12 → `Profiles.del`）。
  Future<void> deleteProfile(int profileId);

  /// 当前 FlClash 所有 profile id（孤儿对账用，§C）。
  List<int> currentProfileIds();
}
