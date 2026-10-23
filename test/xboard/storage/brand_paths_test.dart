import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/storage/brand_paths.dart';
import 'package:fl_clash/xboard/storage/legacy_brand_migration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'confirmed record migration is idempotent and a new logout wins',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final root = await Directory.systemTemp.createTemp('owned-record-');
      addTearDown(() => root.delete(recursive: true));
      final key = ownedRecordKey('brand_a');
      final raw = jsonEncode({
        'version': 2,
        'backend': 'fallback',
        'value': 'cipher',
      });
      final file = File('${root.path}/old.json');
      await file.writeAsString(jsonEncode({'flutter.$key': raw}));
      final before = await file.readAsBytes();
      await migrateOwnedRecordFromFiles(
        prefs: prefs,
        files: [file],
        flavor: 'brand_a',
      );
      expect(prefs.getString(key), raw);
      final logout = jsonEncode({'version': 2, 'backend': 'secure'});
      await prefs.setString(key, logout);
      await migrateOwnedRecordFromFiles(
        prefs: prefs,
        files: [file],
        flavor: 'brand_a',
      );
      expect(prefs.getString(key), logout);
      expect(await file.readAsBytes(), before);
      await migrateOwnedRecordFromFiles(
        prefs: prefs,
        files: [file],
        flavor: 'brand_b',
      );
      expect(prefs.getString(ownedRecordKey('brand_b')), isNull);
    },
  );

  test(
    'Linux brand roots ignore shared legacy executable directories',
    () async {
      final root = await Directory.systemTemp.createTemp('brand-roots-');
      addTearDown(() => root.delete(recursive: true));
      final old = Directory('${root.path}/.local/share/FlClash');
      await old.create(recursive: true);
      final env = {'HOME': root.path};
      final a = await linuxBrandDirectory(
        cache: false,
        environment: env,
        id: 'com.cloud.app.omofly',
      );
      final b = await linuxBrandDirectory(
        cache: false,
        environment: env,
        id: 'com.cloud.app.daishu',
      );
      expect(a.path, isNot(b.path));
      expect(a.path, isNot(old.path));
      expect(await old.exists(), isTrue);
      await expectLater(
        linuxBrandDirectory(cache: false, environment: env, id: '../FlClash'),
        throwsStateError,
      );
    },
  );
  test('legacy selection accepts only the exact brand encrypted record', () {
    final raw = jsonEncode({
      'version': 2,
      'backend': 'fallback',
      'value': 'encrypted-public-fixture',
    });
    final values = {
      'flutter.${ownedRecordKey('brand_a')}': raw,
      'flutter.${ownedRecordKey('brand_b')}': jsonEncode({
        'version': 2,
        'backend': 'secure',
        'key': 'private-key',
      }),
    };
    expect(selectOwnedLegacyRecord(values, 'brand_a'), raw);
    expect(selectOwnedLegacyRecord(values, 'brand_b'), isNull);
    expect(
      selectOwnedLegacyRecord({
        'flutter.xb_access_token_v1': 'unowned',
      }, 'brand_a'),
      isNull,
    );
    expect(
      selectOwnedLegacyRecord({
        ...values,
        ownedRecordKey('brand_a'): 'conflict',
      }, 'brand_a'),
      isNull,
    );
  });
  test('legacy reader rejects links and preserves source bytes', () async {
    final root = await Directory.systemTemp.createTemp('brand-migration-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/prefs');
    await file.writeAsString('{"fixture":true}');
    final before = await file.readAsBytes();
    expect(await readLegacyPreferences(file), {'fixture': true});
    final link = Link('${root.path}/link');
    await link.create(file.path);
    expect(await readLegacyPreferences(File(link.path)), isNull);
    expect(await file.readAsBytes(), before);
  });
}
