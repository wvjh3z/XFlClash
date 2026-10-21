import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart'
    show QueryExecutorUser, QueryExecutor, OpeningDetails, driftRuntimeOptions;
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/xboard/services/profile_sync_port.dart';
import 'package:fl_clash/xboard/storage/profile_database_access.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/dart_executable.dart';

class _UnmigratedDatabase implements QueryExecutorUser {
  @override
  int get schemaVersion => 0;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  for (final code in [5, 261]) {
    test(
      'busy $code retries a fixed operation then returns its result',
      () async {
        var attempts = 0;
        var checks = 0;
        final waits = <Duration>[];
        final value = await retryProfileDatabaseWrite(
          () async {
            attempts++;
            if (attempts < 3) throw SqliteException(code, 'busy');
            return 42;
          },
          ensureCurrent: () => checks++,
          wait: (duration) async => waits.add(duration),
        );
        expect(value, 42);
        expect(attempts, 3);
        expect(checks, 5);
        expect(waits, List.filled(2, const Duration(milliseconds: 100)));
      },
    );
  }

  for (final code in [6, 517, 19, 8, 10, 11]) {
    test('code $code is not retried or swallowed', () async {
      var attempts = 0;
      final error = SqliteException(code, 'failure');
      await expectLater(
        retryProfileDatabaseWrite(
          () async {
            attempts++;
            throw error;
          },
          ensureCurrent: () {},
          wait: (_) async => fail('must not wait'),
        ),
        throwsA(same(error)),
      );
      expect(attempts, 1);
    });
  }

  test(
    'persistent busy stops after three attempts preserving original error',
    () async {
      var attempts = 0;
      final error = SqliteException(5, 'busy');
      await expectLater(
        retryProfileDatabaseWrite(
          () async {
            attempts++;
            throw error;
          },
          ensureCurrent: () {},
          wait: (_) async {},
        ),
        throwsA(same(error)),
      );
      expect(attempts, 3);
    },
  );

  test('logout during backoff prevents the next database attempt', () async {
    var current = true;
    var attempts = 0;
    await expectLater(
      retryProfileDatabaseWrite(
        () async {
          attempts++;
          throw SqliteException(5, 'busy');
        },
        ensureCurrent: () {
          if (!current) throw const ProfileSyncCancelled();
        },
        wait: (_) async => current = false,
      ),
      throwsA(isA<ProfileSyncCancelled>()),
    );
    expect(attempts, 1);
  });

  test(
    'fresh schema lock failure is bounded; fresh connection works after release',
    () async {
      final temp = await Directory.systemTemp.createTemp('xb-schema-');
      final file = File('${temp.path}/database.sqlite');
      final raw = NativeDatabase(file);
      await raw.ensureOpen(_UnmigratedDatabase());
      await raw.runCustom('BEGIN IMMEDIATE');
      final client = Database(openProfileDatabase(file));
      try {
        await expectLater(
          client.profilesDao.query().get(),
          throwsA(
            predicate<Object>(
              (e) => profileSqliteException(e)?.resultCode == 5,
            ),
          ),
        );
        await raw.runCustom('ROLLBACK');
        // Drift retains migration failures. Do not replay partial migrations on
        // a poisoned connection or blindly retry arbitrary transactions.
        final reopened = Database(openProfileDatabase(file));
        try {
          expect(await reopened.profilesDao.query().get(), isEmpty);
        } finally {
          await reopened.close();
        }
      } finally {
        await client.close();
        await raw.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'standalone Dart worker verifies actual SQLite wait budget and recovery',
    () async {
      final process = await Process.start(dartExecutable(), [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        'test/xboard/storage/fixtures/database_busy_process.dart',
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        final code = await process.exitCode.timeout(
          const Duration(seconds: 45),
        );
        expect(code, 0, reason: '${await output} ${await errors}');
        expect(
          (await output).trim(),
          'schema=ok recovery=2 bounded=3 responsive=true',
        );
        expect(await errors, isEmpty);
      } finally {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 15));
      }
    },
  );

  group('real SQLite file and production background connection', () {
    late Directory temp;
    late File file;
    late Database holder;
    late Database client;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('xb-db-中文-');
      file = File('${temp.path}/database.sqlite');
      holder = Database(openProfileDatabase(file));
      await holder.customSelect('SELECT 1').get();
      client = Database(openProfileDatabase(file));
      await client.customSelect('SELECT 1').get();
    });
    tearDown(() async {
      await client.close();
      await holder.close();
      await temp.delete(recursive: true);
    });
    const profile = Profile(
      id: 123,
      label: '袋鼠加速',
      autoUpdateDuration: Duration(days: 1),
    );

    test(
      'busy handler is installed on actual worker; schema and journal remain unchanged',
      () async {
        expect(
          (await client.customSelect('PRAGMA busy_timeout').getSingle())
              .data
              .values
              .single,
          1000,
        );
        expect(
          (await client.customSelect('PRAGMA journal_mode').getSingle())
              .data
              .values
              .single,
          'delete',
        );
        expect(
          (await client.customSelect('PRAGMA user_version').getSingle())
              .data
              .values
              .single,
          2,
        );
      },
    );

    test(
      'first real INSERT fails busy; release between attempts yields exactly one row',
      () async {
        await holder.customStatement('BEGIN IMMEDIATE');
        var attempts = 0;
        try {
          await retryProfileDatabaseWrite(
            () {
              attempts++;
              return client.profiles.put(profile.toCompanion());
            },
            ensureCurrent: () {},
            wait: (_) => holder.customStatement('ROLLBACK'),
          );
        } finally {
          if (attempts == 1) await holder.customStatement('ROLLBACK');
        }
        expect(attempts, 2);
        final rows = await client.profilesDao.query().get();
        expect(rows.map((e) => e.id), [123]);
        expect(rows.single.label, '袋鼠加速');
      },
    );

    test(
      'persistent real lock is finite; UI isolate stays responsive; no delayed write',
      () async {
        await holder.customStatement('BEGIN IMMEDIATE');
        var attempts = 0;
        var ticks = 0;
        final timer = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) => ticks++,
        );
        try {
          await expectLater(
            retryProfileDatabaseWrite(() {
              attempts++;
              return client.profiles.put(profile.toCompanion());
            }, ensureCurrent: () {}).timeout(const Duration(seconds: 20)),
            throwsA(
              predicate<Object>(
                (e) => profileSqliteException(e)?.resultCode == 5,
              ),
            ),
          );
        } finally {
          timer.cancel();
          await holder.customStatement('ROLLBACK');
        }
        expect(attempts, 3);
        expect(ticks, greaterThan(0));
        expect(await client.profilesDao.query().get(), isEmpty);
        await client.profiles.put(profile.toCompanion());
        expect((await client.profilesDao.query().get()).length, 1);
      },
    );
  });
}
