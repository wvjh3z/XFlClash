import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/models/models.dart';
import 'xboard_config.dart';

/// Kept until the brand default is durably saved, before any UI can change it.
String get xbInitialTlsPendingKey =>
    'xb_initial_tls_pending_v1_${XboardConfig.current.flavorId}';

Future<Config> xbMigrateWithInitialTlsDefault({
  required Future<Config> Function() migrate,
  required Future<bool> Function(Config) save,
}) async {
  if (!XboardConfig.current.formA) return migrate();
  final prefs = await SharedPreferences.getInstance();
  // A failed write can mutate SharedPreferences' cache. Always read persisted
  // state for retries; a corrupt existing config is never a fresh install.
  await prefs.reload();
  final key = xbInitialTlsPendingKey;
  var pending = prefs.getBool(key) == true;
  if (!pending &&
      !prefs.containsKey(configKey) &&
      !prefs.containsKey(clashConfigKey)) {
    if (!await prefs.setBool(key, true)) {
      throw StateError('Failed to record initial brand TLS preference');
    }
    await prefs.reload();
    if (prefs.getBool(key) != true) {
      throw StateError('Initial brand TLS preference marker was not persisted');
    }
    pending = true;
  }
  final config = await migrate();
  if (!pending) return config;
  final initial = config.copyWith(
    appSettingProps: config.appSettingProps.copyWith(checkCertificate: false),
  );
  if (!await save(initial)) {
    throw StateError('Failed to save initial brand TLS preference');
  }
  await prefs.reload();
  final raw = prefs.getString(configKey);
  final stored = raw == null ? null : jsonDecode(raw);
  if (stored is! Map ||
      stored['appSettingProps'] is! Map ||
      (stored['appSettingProps'] as Map)['checkCertificate'] != false) {
    throw StateError('Initial brand TLS preference was not persisted');
  }
  if (!await prefs.remove(key)) {
    throw StateError('Failed to complete initial brand TLS preference');
  }
  await prefs.reload();
  if (prefs.containsKey(key)) {
    throw StateError('Initial brand TLS completion was not persisted');
  }
  return initial;
}
