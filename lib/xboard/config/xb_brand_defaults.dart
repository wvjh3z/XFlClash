import 'dart:convert';

import 'package:fl_clash/common/constant.dart' show configKey;
import 'package:fl_clash/models/models.dart' show Config;
import 'package:prism_ui/prism_ui.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import 'xb_tls_defaults.dart';
import 'xboard_config.dart';

/// Apply brand defaults before building the root ProviderContainer. Only the
/// first boot with this policy replaces a previously selected theme mode.
Future<Config> xbMigrateBrandDefaults({
  required Future<Config> Function() migrate,
  required Future<bool> Function(Config) save,
}) async {
  final config = await xbMigrateWithInitialTlsDefault(migrate: migrate, save: save);
  final brand = XboardConfig.current;
  if (!brand.formA) return config;
  final prefs = await SharedPreferences.getInstance();
  final marker = 'xb_light_theme_applied_v1_${brand.flavorId}';
  // The preceding migration reloads the same SharedPreferences instance.
  if (prefs.getBool(marker) == true) return config;

  final light = config.copyWith(themeProps: config.themeProps.copyWith(themeMode: ThemeMode.light));
  if (!await save(light)) throw StateError('Failed to save initial light theme');
  await prefs.reload();
  final raw = prefs.getString(configKey);
  final stored = raw == null ? null : jsonDecode(raw);
  if (stored is! Map || stored['themeProps'] is! Map ||
      stored['themeProps']['themeMode'] != 'light') {
    throw StateError('Initial light theme was not persisted');
  }
  if (!await prefs.setBool(marker, true)) throw StateError('Failed to mark light theme migration');
  await prefs.reload();
  if (prefs.getBool(marker) != true) throw StateError('Light theme migration was not persisted');
  return light;
}
