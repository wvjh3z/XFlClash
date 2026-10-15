import 'package:shared_preferences/shared_preferences.dart';

/// Device-wide reporting preference; independent of account and the 24-hour refresh.
const kSentryReportingEnabledKey = 'xb_sentry_reporting_enabled_v1';

class SentryReportingPreferenceStore {
  SentryReportingPreferenceStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  /// Existing installs retain reporting unless a user explicitly disables it.
  Future<bool> readEnabled() async {
    final preferences = await _preferences();
    return preferences.getBool(kSentryReportingEnabledKey) ?? true;
  }

  Future<void> writeEnabled(bool enabled) async {
    final preferences = await _preferences();
    try {
      if (await preferences.setBool(kSentryReportingEnabledKey, enabled)) {
        return;
      }
    } catch (_) {
      // SharedPreferences updates its cache before completing the platform write.
      // Reload below so a failed write cannot appear saved after a local retry.
    }
    try {
      await preferences.reload();
    } catch (_) {
      // The write is still a failure if the cache cannot be refreshed.
    }
    throw StateError('Could not save crash reporting preference');
  }
}
