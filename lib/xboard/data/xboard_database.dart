/// Xboard 外挂索引数据库（决策 #3 / R7.6 / DD-22）—— **独立 Drift 库**，不碰 FlClash schema。
///
/// **为什么外挂**（F404）：FlClash `Profiles` 表无 source/flavor/token 字段，客户端需自维护
/// `profileId ↔ (flavorId, userIdHash)` 映射，用于退出登录精确删除 Xboard 同步的 profile（R7.12）
/// + R7.6 去重（按 flavorId+userIdHash 而非 url，因 endpoint 切换会改 url）。
///
/// **表前缀 `xboard_`**（决策 #3）防与 FlClash 主仓表碰撞；独立 .sqlite 文件（不入 FlClash Database）。
/// schemaVersion=1 + MigrationStrategy 占位（DD-22）。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part '../generated/data/xboard_database.g.dart';

/// profile 外挂索引表（R7.6 / 决策 #3）。
/// profileId 是 FlClash `Profile.id`（int，snowflake；`Profiles.del(int)`）。
class XboardProfileIndexV1 extends Table {
  /// FlClash profile id（主键）。
  IntColumn get profileId => integer()();

  /// 所属 flavor（多 flavor 隔离）。
  TextColumn get flavorId => text()();

  /// 用户 hash（token sha256 前缀；切账号天然区分，ε4）。
  TextColumn get userIdHash => text()();

  @override
  Set<Column> get primaryKey => {profileId};
}

@DriftDatabase(tables: [XboardProfileIndexV1])
class XboardDatabase extends _$XboardDatabase {
  XboardDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'xboard_index'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          // DD-22 占位：v2 schema 升级时在此迁移。
        },
      );

  /// 记录索引（新建 profile 后；冲突则覆盖）。
  Future<void> putIndex({
    required int profileId,
    required String flavorId,
    required String userIdHash,
  }) =>
      into(xboardProfileIndexV1).insertOnConflictUpdate(
        XboardProfileIndexV1Companion(
          profileId: Value(profileId),
          flavorId: Value(flavorId),
          userIdHash: Value(userIdHash),
        ),
      );

  /// R7.6 去重查询：当前 flavor + userIdHash 已有的 profileId（无则 null）。
  Future<int?> findProfileId({
    required String flavorId,
    required String userIdHash,
  }) async {
    final row = await (select(xboardProfileIndexV1)
          ..where((t) => t.flavorId.equals(flavorId) & t.userIdHash.equals(userIdHash)))
        .getSingleOrNull();
    return row?.profileId;
  }

  /// 删索引（退出登录 / 孤儿清理）。
  Future<void> deleteByProfileId(int profileId) =>
      (delete(xboardProfileIndexV1)..where((t) => t.profileId.equals(profileId)))
          .go();

  /// 全部索引行（孤儿对账用，§C）。
  Future<List<XboardProfileIndexV1Data>> allRows() =>
      select(xboardProfileIndexV1).get();
}
