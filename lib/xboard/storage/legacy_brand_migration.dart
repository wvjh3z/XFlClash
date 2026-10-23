/// Copy only positively attributed encrypted records. Never move/delete shared data.
library;

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'brand_paths.dart';

String ownedRecordKey(String flavor) =>
    'xb_access_token_v1_${Uri.encodeComponent(flavor)}_record_v2';

String? selectOwnedLegacyRecord(Map<String, dynamic> values, String flavor) {
  if (!{'brand_a', 'brand_b'}.contains(flavor)) return null;
  final key = ownedRecordKey(flavor);
  final candidates = [
    values[key],
    values['flutter.$key'],
  ].whereType<String>().toSet();
  if (candidates.length != 1) return null;
  final raw = candidates.single;
  try {
    final record = jsonDecode(raw);
    if (record is! Map ||
        record['version'] != 2 ||
        record['backend'] != 'fallback' ||
        record.containsKey('key') ||
        (record['value'] != null && record['value'] is! String)) {
      return null;
    }
    return raw;
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> readLegacyPreferences(
  File file, {
  bool plist = false,
}) async {
  try {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 2 * 1024 * 1024) {
      return null;
    }
    final String raw;
    if (plist) {
      final process = await Process.run('/usr/bin/plutil', [
        '-convert',
        'json',
        '-o',
        '-',
        file.path,
      ]).timeout(const Duration(seconds: 3));
      if (process.exitCode != 0) return null;
      raw = process.stdout as String;
    } else {
      raw = await file.readAsString();
    }
    final value = jsonDecode(raw);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  } catch (_) {
    return null;
  }
}

Future<void> migrateOwnedDesktopPreference({
  String flavor = const String.fromEnvironment('XB_FLAVOR_ID'),
}) async {
  if (!isolatedDesktopBrand) return;
  final prefs = await SharedPreferences.getInstance();
  final key = ownedRecordKey(flavor);
  if (prefs.containsKey(key)) {
    return;
  } // New data (including logout) always wins.
  final env = Platform.environment;
  final files = <File>[];
  if (Platform.isWindows && env['APPDATA'] != null) {
    files.add(
      File(
        p.join(
          env['APPDATA']!,
          'com.follow',
          'clash',
          'shared_preferences.json',
        ),
      ),
    );
  } else if (Platform.isLinux && env['HOME'] != null) {
    final custom = env['XDG_DATA_HOME'];
    final root = custom != null && p.isAbsolute(custom)
        ? custom
        : p.join(env['HOME']!, '.local/share');
    for (final name in ['com.follow.clash', 'FlClash']) {
      files.add(File(p.join(root, name, 'shared_preferences.json')));
    }
  } else if (Platform.isMacOS && env['HOME'] != null) {
    files.add(
      File(p.join(env['HOME']!, 'Library/Preferences/com.follow.clash.plist')),
    );
  }
  await migrateOwnedRecordFromFiles(
    prefs: prefs,
    files: files,
    flavor: flavor,
    plist: Platform.isMacOS,
  );
}

Future<void> migrateOwnedRecordFromFiles({
  required SharedPreferences prefs,
  required List<File> files,
  required String flavor,
  bool plist = false,
}) async {
  final key = ownedRecordKey(flavor);
  if (prefs.containsKey(key)) return;
  final matches = <String>{};
  for (final file in files) {
    final values = await readLegacyPreferences(file, plist: plist);
    final record = values == null
        ? null
        : selectOwnedLegacyRecord(values, flavor);
    if (record != null) matches.add(record);
  }
  // Conflicting old locations are not resolved by timestamp or guessing.
  if (matches.length != 1) return;
  if (!await prefs.setString(key, matches.single)) {
    throw StateError('Brand preference migration could not be saved');
  }
  await prefs.reload();
  if (prefs.getString(key) != matches.single) {
    throw StateError('Brand preference migration could not be verified');
  }
}
