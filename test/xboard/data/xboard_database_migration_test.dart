import 'dart:io';

import 'package:drift/drift.dart' show MigrationStrategy, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/xboard/data/xboard_database.dart';

const _tableSql = 'CREATE TABLE xboard_profile_index_v1 '
    '(profile_id INTEGER NOT NULL PRIMARY KEY, flavor_id TEXT NOT NULL, '
    'user_id_hash TEXT NOT NULL)';
const _managed = ['xboard_index_owner_insert', 'xboard_index_owner_update'];

enum _Fault { beforeSecond, afterSecond, afterCallback }

class _InterruptedDatabase extends XboardDatabase {
  _InterruptedDatabase(super.executor, this.fault);
  final _Fault fault;

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    final second = statement.startsWith('CREATE TRIGGER xboard_index_owner_update');
    if (second && fault == _Fault.beforeSecond) throw StateError('before second DDL');
    await super.customStatement(statement, args);
    if (second && fault == _Fault.afterSecond) throw StateError('after second DDL');
  }

  @override
  MigrationStrategy get migration {
    final actual = super.migration;
    if (fault != _Fault.afterCallback) return actual;
    // Exercise the committed-DDL / unadvanced-user_version window, without
    // pretending a callback exception is a real process kill or disk failure.
    return MigrationStrategy(
      onCreate: (m) async {
        await actual.onCreate(m);
        throw StateError('before version commit');
      },
      onUpgrade: (m, from, to) async {
        await actual.onUpgrade(m, from, to);
        throw StateError('before version commit');
      },
    );
  }
}

Future<void> _closeFailed(XboardDatabase db) async {
  // Drift may rethrow the failed-open error while closing the executor.
  try { await db.close(); } catch (_) {}
}

Future<void> _healthy(XboardDatabase db, String brand, {required bool seeded}) async {
  final rows = await db.allRows();
  expect(rows.map((r) => (r.profileId, r.flavorId, r.userIdHash)).toSet(),
      seeded ? {(1, brand, 'owner'), (2, brand, 'owner'), (3, 'other', 'owner')} : isEmpty);
  expect((await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 2);
  final triggers = await db.customSelect("SELECT name FROM sqlite_master WHERE type='trigger'").get();
  expect(triggers.map((r) => r.read<String>('name')).toSet(),
      seeded ? {..._managed, 'fixture_unrelated'} : _managed.toSet());
  if (!seeded) await db.putIndex(profileId: 1, flavorId: brand, userIdHash: 'owner');
  await expectLater(db.putIndex(profileId: 9, flavorId: brand, userIdHash: 'owner'),
      throwsA(isA<SqliteException>()));
  await expectLater(db.customStatement(
      "UPDATE xboard_profile_index_v1 SET user_id_hash='changed' WHERE profile_id=1"),
      throwsA(isA<SqliteException>()));
  await db.putIndex(profileId: 9, flavorId: brand, userIdHash: 'new-owner');
  await db.deleteByProfileId(9);
  if (!seeded) await db.deleteByProfileId(1);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  for (final brand in ['brand_a', 'brand_b']) {
    for (final fresh in [true, false]) {
      for (final fault in _Fault.values) {
        test('$brand fresh=$fresh $fault rolls back or safely reopens', () async {
          final dir = await Directory.systemTemp.createTemp('xb-migration-中文 ');
          addTearDown(() => dir.delete(recursive: true));
          final file = File('${dir.path}/index.sqlite');
          final first = _InterruptedDatabase(NativeDatabase(file, setup: (sql) {
            if (!fresh) {
              sql.execute(_tableSql);
              sql.execute("INSERT INTO xboard_profile_index_v1 VALUES (1, ?, 'owner'), (2, ?, 'owner'), (3, 'other', 'owner')", [brand, brand]);
              sql.execute('CREATE TRIGGER fixture_unrelated AFTER DELETE ON xboard_profile_index_v1 BEGIN SELECT 1; END');
              sql.execute('PRAGMA user_version = 1');
            }
          }), fault);
          try { await expectLater(first.allRows(), throwsStateError); }
          finally { await _closeFailed(first); }
          var versionBefore = -1;
          var tableCountBefore = -1;
          var guardCountBefore = -1;
          final reopened = XboardDatabase(NativeDatabase(file, setup: (sql) {
            versionBefore = sql.select('PRAGMA user_version').single['user_version'] as int;
            tableCountBefore = sql.select("SELECT name FROM sqlite_master WHERE type='table' AND name='xboard_profile_index_v1'").length;
            guardCountBefore = sql.select("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'xboard_index_owner_%'").length;
          }));
          try {
            await _healthy(reopened, brand, seeded: !fresh);
            expect(versionBefore, fresh ? 0 : 1);
            expect(guardCountBefore, fault == _Fault.afterCallback ? 2 : 0);
            expect(tableCountBefore, fresh && fault != _Fault.afterCallback ? 0 : 1);
          } finally { await reopened.close(); }
          final again = XboardDatabase(NativeDatabase(file));
          try { await _healthy(again, brand, seeded: !fresh); }
          finally { await again.close(); }
        });
      }
    }

    test('$brand failed repair restores preexisting trigger definitions', () async {
      final dir = await Directory.systemTemp.createTemp('xb-repair-rollback-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/index.sqlite');
      final first = _InterruptedDatabase(NativeDatabase(file, setup: (sql) {
        sql.execute(_tableSql);
        sql.execute("INSERT INTO xboard_profile_index_v1 VALUES (1, ?, 'owner'), (2, ?, 'owner'), (3, 'other', 'owner')", [brand, brand]);
        sql.execute('CREATE TRIGGER fixture_unrelated AFTER DELETE ON xboard_profile_index_v1 BEGIN SELECT 1; END');
        for (final name in _managed) {
          sql.execute('CREATE TRIGGER $name BEFORE INSERT ON xboard_profile_index_v1 BEGIN SELECT 17; END');
        }
        sql.execute('PRAGMA user_version = 1');
      }), _Fault.beforeSecond);
      try { await expectLater(first.allRows(), throwsStateError); }
      finally { await _closeFailed(first); }
      var oldDefinitions = <String>[];
      final reopened = XboardDatabase(NativeDatabase(file, setup: (sql) {
        oldDefinitions = sql.select("SELECT sql FROM sqlite_master WHERE type='trigger' AND name LIKE 'xboard_index_owner_%'")
            .map((row) => row['sql'] as String).toList();
      }));
      try {
        await _healthy(reopened, brand, seeded: true);
        expect(oldDefinitions, hasLength(2));
        expect(oldDefinitions.every((sql) => sql.contains('SELECT 17')), isTrue);
      } finally { await reopened.close(); }
    });

    for (final version in [0, 1]) {
      for (final names in [<String>[], [_managed[0]], [_managed[1]], _managed]) {
        test('$brand v$version partial guards=${names.length}/${names.join(',')} recover without dropping rows', () async {
          final dir = await Directory.systemTemp.createTemp('xb-partial-migration-');
          addTearDown(() => dir.delete(recursive: true));
          final file = File('${dir.path}/index.sqlite');
          final db = XboardDatabase(NativeDatabase(file, setup: (sql) {
            sql.execute(_tableSql);
            sql.execute("INSERT INTO xboard_profile_index_v1 VALUES (1, ?, 'owner'), (2, ?, 'owner'), (3, 'other', 'owner')", [brand, brand]);
            sql.execute('CREATE TRIGGER fixture_unrelated AFTER DELETE ON xboard_profile_index_v1 BEGIN SELECT 1; END');
            for (final name in names) {
              // Deliberately wrong definitions: IF NOT EXISTS alone would keep
              // these ineffective guards and must fail the behavioral checks.
              sql.execute('CREATE TRIGGER $name BEFORE INSERT ON xboard_profile_index_v1 BEGIN SELECT 1; END');
            }
            sql.execute('PRAGMA user_version = $version');
          }));
          try { await _healthy(db, brand, seeded: true); }
          finally { await db.close(); }
          final reopened = XboardDatabase(NativeDatabase(file));
          try { await _healthy(reopened, brand, seeded: true); }
          finally { await reopened.close(); }
        });
      }
    }
  }
}
