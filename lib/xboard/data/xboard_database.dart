/// Xboard 外挂索引数据库（决策 #3 / R7.6 / DD-22）—— **独立 Drift 库**，不碰 FlClash schema。
///
/// **为什么外挂**（F404）：FlClash `Profiles` 表无 source/flavor/token 字段，客户端需自维护
/// `profileId ↔ (flavorId, userIdHash)` 映射，用于退出登录精确删除 Xboard 同步的 profile（R7.12）
/// + R7.6 去重（按 flavorId+userIdHash 而非 url，因 endpoint 切换会改 url）。
///
/// **表前缀 `xboard_`**（决策 #3）防与 FlClash 主仓表碰撞；独立 .sqlite 文件（不入 FlClash Database）。
/// Schema 2 preserves legacy rows and rejects new ownership conflicts.
library;

import 'dart:io';
import 'package:fl_clash/common/path.dart' show appPath;
import '../storage/brand_paths.dart';
import '../storage/profile_mutation_queue.dart';

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
  final profileMutations = ProfileMutationQueue();

  XboardDatabase([QueryExecutor? executor])
    : super(
        executor ??
            driftDatabase(
              name: 'xboard_index',
              native: isolatedDesktopBrand
                  ? DriftNativeOptions(
                      databaseDirectory: () async =>
                          Directory(await appPath.homeDirPath),
                    )
                  : null,
            ),
      );

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => transaction(() async {
      await m.createAll();
      await _createOwnershipGuards();
    }),
    onUpgrade: (m, from, to) async {
      if (from < 2) await transaction(_createOwnershipGuards);
    },
  );

  // Do not discard duplicate legacy rows during migration: only the Profile
  // port can safely stop/delete their files and main DB entries. Triggers block
  // new duplicates while retaining every old cleanup/recovery reference.
  Future<void> _createOwnershipGuards() async {
    // Drift commits user_version after the migration callback. A previous
    // attempt may have committed DDL without advancing that version. Reinstall
    // only our two triggers in the caller's transaction; never discard rows or
    // trust a partially installed trigger definition via IF NOT EXISTS alone.
    await customStatement('DROP TRIGGER IF EXISTS xboard_index_owner_insert');
    await customStatement('DROP TRIGGER IF EXISTS xboard_index_owner_update');
    await customStatement('''CREATE TRIGGER xboard_index_owner_insert
      BEFORE INSERT ON xboard_profile_index_v1
      WHEN EXISTS (SELECT 1 FROM xboard_profile_index_v1 WHERE
        (profile_id = NEW.profile_id AND
          (flavor_id != NEW.flavor_id OR user_id_hash != NEW.user_id_hash)) OR
        (profile_id != NEW.profile_id AND flavor_id = NEW.flavor_id
          AND user_id_hash = NEW.user_id_hash))
      BEGIN SELECT RAISE(ABORT, 'Profile ownership conflict'); END''');
    await customStatement('''CREATE TRIGGER xboard_index_owner_update
      BEFORE UPDATE ON xboard_profile_index_v1
      WHEN NEW.profile_id != OLD.profile_id OR NEW.flavor_id != OLD.flavor_id
        OR NEW.user_id_hash != OLD.user_id_hash
      BEGIN SELECT RAISE(ABORT, 'Profile ownership is immutable'); END''');
  }

  /// Reserve ownership before file/main-DB writes; identical ownership is idempotent.
  Future<void> putIndex({
    required int profileId,
    required String flavorId,
    required String userIdHash,
  }) => into(xboardProfileIndexV1).insertOnConflictUpdate(
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
    final row =
        await (select(xboardProfileIndexV1)..where(
              (t) =>
                  t.flavorId.equals(flavorId) & t.userIdHash.equals(userIdHash),
            ))
            .getSingleOrNull();
    return row?.profileId;
  }

  /// 会话结束时枚举旧账号的全部索引，包括历史版本留下的重复归属记录。
  /// 不改变 schema 或同步去重规则；清理不能依赖 getSingleOrNull。
  Future<List<int>> findProfileIds({
    required String flavorId,
    required String userIdHash,
  }) async {
    final rows =
        await (select(xboardProfileIndexV1)
              ..where(
                (t) =>
                    t.flavorId.equals(flavorId) &
                    t.userIdHash.equals(userIdHash),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.profileId)]))
            .get();
    return rows.map((row) => row.profileId).toList();
  }

  /// 删索引（退出登录 / 孤儿清理）。
  Future<void> deleteByProfileId(int profileId) => (delete(
    xboardProfileIndexV1,
  )..where((t) => t.profileId.equals(profileId))).go();

  /// 全部索引行（孤儿对账用，§C）。
  Future<List<XboardProfileIndexV1Data>> allRows() =>
      select(xboardProfileIndexV1).get();
}
