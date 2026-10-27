/// W6.3 — XboardProfileIndex Drift 表：增删查 + 去重判定 + schemaVersion=2。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/data/xboard_database.dart';

void main() {
  late XboardDatabase db;
  setUp(() => db = XboardDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('schemaVersion=2', () {
    expect(db.schemaVersion, 2);
  });

  test('putIndex + findProfileId 去重（flavorId + userIdHash）', () async {
    await db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashA');
    expect(
      await db.findProfileId(flavorId: 'brandA', userIdHash: 'hashA'),
      100,
    );
    // 不同 flavor / user → miss
    expect(
      await db.findProfileId(flavorId: 'brandB', userIdHash: 'hashA'),
      isNull,
    );
    expect(
      await db.findProfileId(flavorId: 'brandA', userIdHash: 'hashB'),
      isNull,
    );
  });

  test('ownership is immutable and identical writes are idempotent', () async {
    await db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashA');
    await db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashA');
    await expectLater(
      db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashB'),
      throwsA(isA<SqliteException>()),
    );
    await expectLater(
      db.putIndex(profileId: 101, flavorId: 'brandA', userIdHash: 'hashA'),
      throwsA(isA<SqliteException>()),
    );
    expect((await db.allRows()).single.userIdHash, 'hashA');
  });

  test('concurrent ownership claims allow only one profile', () async {
    Future<bool> claim(int id) async {
      try {
        await db.putIndex(profileId: id, flavorId: 'f', userIdHash: 'h');
        return true;
      } on SqliteException {
        return false;
      }
    }
    final outcomes = await Future.wait([claim(1), claim(2)]);
    expect(outcomes.where((success) => success), hasLength(1));
    expect(await db.allRows(), hasLength(1));
    await expectLater(
      db.customStatement("UPDATE xboard_profile_index_v1 SET user_id_hash = 'other'"),
      throwsA(isA<SqliteException>()),
    );
    expect((await db.allRows()).single.userIdHash, 'h');
  });

  test('v1 duplicate migration preserves recovery evidence and guards future writes', () async {
    final legacy = XboardDatabase(NativeDatabase.memory(setup: (db) {
      db.execute('CREATE TABLE xboard_profile_index_v1 (profile_id INTEGER NOT NULL PRIMARY KEY, flavor_id TEXT NOT NULL, user_id_hash TEXT NOT NULL)');
      db.execute("INSERT INTO xboard_profile_index_v1 VALUES (1, 'f', 'h'), (2, 'f', 'h')");
      db.execute('PRAGMA user_version = 1');
    }));
    addTearDown(legacy.close);
    expect(await legacy.findProfileIds(flavorId: 'f', userIdHash: 'h'), [1, 2]);
    await expectLater(legacy.putIndex(profileId: 3, flavorId: 'f', userIdHash: 'h'), throwsA(isA<SqliteException>()));
    await legacy.deleteByProfileId(2);
    await legacy.putIndex(profileId: 1, flavorId: 'f', userIdHash: 'h');
    expect((await legacy.allRows()).single.profileId, 1);
    expect((await legacy.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 2);
  });

  test('deleteByProfileId', () async {
    await db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashA');
    await db.deleteByProfileId(100);
    expect(
      await db.findProfileId(flavorId: 'brandA', userIdHash: 'hashA'),
      isNull,
    );
  });

  test('allRows', () async {
    await db.putIndex(profileId: 1, flavorId: 'f', userIdHash: 'h1');
    await db.putIndex(profileId: 2, flavorId: 'f', userIdHash: 'h2');
    expect(await db.allRows(), hasLength(2));
  });

  test('findProfileIds 枚举同归属全部重复记录，不跨 flavor 或账号', () async {
    await db.putIndex(profileId: 1, flavorId: 'brandA', userIdHash: 'hashA');
    await db.customStatement('DROP TRIGGER xboard_index_owner_insert');
    await db.putIndex(profileId: 2, flavorId: 'brandA', userIdHash: 'hashA');
    await db.putIndex(profileId: 3, flavorId: 'brandB', userIdHash: 'hashA');
    await db.putIndex(profileId: 4, flavorId: 'brandA', userIdHash: 'hashB');
    expect(await db.findProfileIds(flavorId: 'brandA', userIdHash: 'hashA'), [
      1,
      2,
    ]);
    expect(
      await db.findProfileIds(flavorId: 'brandA', userIdHash: 'missing'),
      isEmpty,
    );
  });
}
