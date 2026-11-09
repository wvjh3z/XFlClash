import 'dart:io';

import 'package:fl_clash/common/constant.dart' show mitmFeature;
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/xboard/storage/profile_database_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    test('$brand schema21 file retains profiles with MITM disabled', () async {
      final directory = await Directory.systemTemp.createTemp('v093-$brand-');
      final file = File('${directory.path}/database.sqlite');
      final original = Database(openProfileDatabase(file));
      try {
        await original.profiles.put(Profile(
          id: 321,
          label: '$brand preserved',
          url: 'https://example.invalid/subscription',
          autoUpdateDuration: const Duration(days: 1),
        ).toCompanion());
      } finally {
        await original.close();
      }
      final raw = sqlite.sqlite3.open(file.path);
      try {
        // Schema21 has the same pre-existing tables, but no MITM module table.
        raw.execute('DROP TABLE mitm_modules');
        raw.execute('PRAGMA user_version = 21');
      } finally {
        raw.dispose();
      }
      final migrated = Database(openProfileDatabase(file));
      try {
        expect(mitmFeature, isFalse);
        final profiles = await migrated.profilesDao.query().get();
        expect(profiles.single.id, 321);
        expect(profiles.single.label, '$brand preserved');
        expect(profiles.single.url, 'https://example.invalid/subscription');
        expect((await migrated.customSelect('PRAGMA user_version').getSingle())
            .data.values.single, 23);
        expect(await migrated.mitmModulesDao.query().get(), isEmpty);
        expect((await migrated.customSelect('PRAGMA foreign_keys').getSingle())
            .data.values.single, 1);
      } finally {
        await migrated.close();
      }
      final reopened = Database(openProfileDatabase(file));
      try {
        expect((await reopened.profilesDao.query().get()).single.id, 321);
      } finally {
        await reopened.close();
        await directory.delete(recursive: true);
      }
    });
  }
}
