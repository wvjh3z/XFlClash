/// W6.3 — XboardProfileIndex Drift 表：增删查 + 去重判定 + schemaVersion=1。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/data/xboard_database.dart';

void main() {
  late XboardDatabase db;
  setUp(() => db = XboardDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('schemaVersion=1', () {
    expect(db.schemaVersion, 1);
  });

  test('putIndex + findProfileId 去重（flavorId + userIdHash）', () async {
    await db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashA');
    expect(await db.findProfileId(flavorId: 'brandA', userIdHash: 'hashA'), 100);
    // 不同 flavor / user → miss
    expect(await db.findProfileId(flavorId: 'brandB', userIdHash: 'hashA'), isNull);
    expect(await db.findProfileId(flavorId: 'brandA', userIdHash: 'hashB'), isNull);
  });

  test('insertOnConflictUpdate：同 profileId 覆盖', () async {
    await db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashA');
    await db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashB');
    expect(await db.findProfileId(flavorId: 'brandA', userIdHash: 'hashB'), 100);
    final rows = await db.allRows();
    expect(rows, hasLength(1)); // 覆盖非新增
  });

  test('deleteByProfileId', () async {
    await db.putIndex(profileId: 100, flavorId: 'brandA', userIdHash: 'hashA');
    await db.deleteByProfileId(100);
    expect(await db.findProfileId(flavorId: 'brandA', userIdHash: 'hashA'), isNull);
  });

  test('allRows', () async {
    await db.putIndex(profileId: 1, flavorId: 'f', userIdHash: 'h1');
    await db.putIndex(profileId: 2, flavorId: 'f', userIdHash: 'h2');
    expect(await db.allRows(), hasLength(2));
  });
}
