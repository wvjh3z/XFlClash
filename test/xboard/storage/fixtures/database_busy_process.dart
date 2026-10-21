import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fl_clash/xboard/storage/profile_database_access.dart';

class _Schema implements QueryExecutorUser {
  @override
  int get schemaVersion => 1;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    await executor.runCustom(
      'CREATE TABLE IF NOT EXISTS profiles(id INTEGER PRIMARY KEY, label TEXT)',
    );
  }
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('xb-db-native-中文-');
  final file = File('${dir.path}/database.sqlite');
  final holder = NativeDatabase(file);
  QueryExecutor client = openProfileDatabase(file);
  var held = false;
  Future<void> hold() async {
    await holder.runCustom('BEGIN IMMEDIATE');
    held = true;
  }

  Future<void> unlock() async {
    await holder.runCustom('ROLLBACK');
    held = false;
  }

  try {
    await holder.ensureOpen(_Schema());
    // Force a schema write from the second connection while the first holds
    // RESERVED. This is a real engine, independent of flutter_tester timing.
    await holder.runCustom('DROP TABLE profiles');
    await hold();
    final clock = Stopwatch()..start();
    try {
      await client.ensureOpen(_Schema());
      throw StateError('schema should fail while held');
    } catch (e) {
      require(
        profileSqliteException(e)?.resultCode == 5,
        'expected schema busy',
      );
      require(clock.elapsedMilliseconds >= 800, 'native busy wait not applied');
    }
    await unlock();
    await client.close();
    client = openProfileDatabase(file);
    await client.ensureOpen(_Schema());
    await hold();
    var attempts = 0;
    await retryProfileDatabaseWrite(
      () {
        attempts++;
        return client.runInsert('INSERT INTO profiles VALUES (?, ?)', [
          1,
          '袋鼠加速',
        ]);
      },
      ensureCurrent: () {},
      wait: (_) => unlock(),
    );
    require(attempts == 2, 'expected one bounded retry');
    require(
      (await client.runSelect('SELECT id FROM profiles', [])).length == 1,
      'duplicate rows',
    );

    await hold();
    attempts = 0;
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => ticks++,
    );
    clock.reset();
    try {
      await retryProfileDatabaseWrite(() {
        attempts++;
        return client.runInsert('INSERT INTO profiles VALUES (?, ?)', [
          2,
          'OmoFly',
        ]);
      }, ensureCurrent: () {});
      throw StateError('persistent lock should fail');
    } catch (e) {
      require(
        profileSqliteException(e)?.resultCode == 5,
        'expected final busy',
      );
      require(attempts == 3, 'unbounded retries');
      require(clock.elapsedMilliseconds >= 2400, 'wait was bypassed');
      require(ticks > 0, 'main isolate blocked');
    } finally {
      timer.cancel();
    }
    await unlock();
    require(
      (await client.runSelect('SELECT id FROM profiles', [])).length == 1,
      'late write after failure',
    );
    stdout.writeln('schema=ok recovery=2 bounded=3 responsive=true');
  } finally {
    if (held) await unlock();
    await client.close();
    await holder.close();
    await dir.delete(recursive: true);
  }
}
