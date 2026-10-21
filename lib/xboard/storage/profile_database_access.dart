import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:drift/isolate.dart' show DriftRemoteException;

// Runs on Drift's worker isolate, including before schema creation/migration.
// No WAL change: the existing backup implementation copies only the main file.
const profileDatabaseBusyTimeoutMs = 1000;

QueryExecutor openProfileDatabase(File file) =>
    NativeDatabase.createInBackground(
      file,
      setup: (db) =>
          db.execute('PRAGMA busy_timeout = $profileDatabaseBusyTimeoutMs'),
    );

/// The production background connection wraps native errors (schema opening
/// may cross the isolate boundary more than once). Never parse error strings.
SqliteException? profileSqliteException(Object error) {
  while (error is DriftRemoteException) {
    error = error.remoteCause;
  }
  return error is SqliteException ? error : null;
}

/// Only for an idempotent autocommit write with a fixed Profile ID/value.
/// Never wrap a transaction, file/network/core action or ID allocation here.
/// At most 3 attempts with a 1s busy handler + two 100ms pauses. This is a
/// contention budget, not a deadline for disk I/O or executor queuing. No timeout
/// leaving a database operation running after its caller has reported failure.
Future<T> retryProfileDatabaseWrite<T>(
  Future<T> Function() write, {
  required void Function() ensureCurrent,
  Future<void> Function(Duration)? wait,
}) async {
  for (var attempt = 0; ; attempt++) {
    ensureCurrent();
    try {
      return await write();
    } catch (error) {
      final sqliteError = profileSqliteException(error);
      // BUSY / BUSY_RECOVERY only. In particular, don't replay a stale
      // transaction snapshot (BUSY_SNAPSHOT), SQLITE_LOCKED or unrelated I/O.
      if (attempt >= 2 ||
          sqliteError == null ||
          (sqliteError.extendedResultCode != 5 &&
              sqliteError.extendedResultCode != 261)) {
        rethrow;
      }
      ensureCurrent();
      await (wait ?? Future<void>.delayed)(const Duration(milliseconds: 100));
    }
  }
}
