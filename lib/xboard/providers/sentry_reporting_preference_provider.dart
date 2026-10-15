import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/xboard_config.dart';
import '../services/sentry_bootstrap.dart';
import '../services/sentry_reporting_preference.dart';

final sentryReportingPreferenceStoreProvider =
    Provider<SentryReportingPreferenceStore>((ref) {
      return SentryReportingPreferenceStore();
    });

final sentryReportingConfiguredProvider = Provider<bool>((ref) {
  return XboardConfig.current.sentryDsn.trim().isNotEmpty;
});

/// Injectable native boundary; preference tests never initialize or contact Sentry.
final sentryReportingApplyOptOutProvider =
    Provider<Future<void> Function(bool optedOut)>((ref) {
      return SentryBootstrap.setUserOptOut;
    });

final sentryReportingRestartRequiredProvider = Provider<bool Function()>((ref) {
  return () => SentryBootstrap.restartRequired;
});

class SentryReportingPreference {
  const SentryReportingPreference({
    required this.enabled,
    required this.configured,
    this.isSaving = false,
    this.runtimeFailed = false,
    this.restartRequired = false,
  });

  /// Saved choice. A missing DSN does not overwrite the device's preference.
  final bool enabled;
  final bool configured;
  final bool isSaving;
  final bool runtimeFailed;
  final bool restartRequired;
}

enum SentryReportingChangeResult {
  success,
  unavailable,
  busy,
  persistenceFailed,
  runtimeFailed,
  restartRequired,
}

/// Kept alive so startup and settings consume the same persisted decision.
final sentryReportingPreferenceProvider =
    AsyncNotifierProvider<
      SentryReportingPreferenceNotifier,
      SentryReportingPreference
    >(
      SentryReportingPreferenceNotifier.new,
      retry: (retryCount, error) => null,
    );

class SentryReportingPreferenceNotifier
    extends AsyncNotifier<SentryReportingPreference> {
  @override
  Future<SentryReportingPreference> build() async {
    final store = ref.watch(sentryReportingPreferenceStoreProvider);
    final configured = ref.watch(sentryReportingConfiguredProvider);
    final needsRestart = ref.watch(sentryReportingRestartRequiredProvider);
    final enabled =
        SentryBootstrap.takeInitialPreferenceRead() ??
        await store.readEnabled();
    return SentryReportingPreference(
      enabled: enabled,
      configured: configured,
      restartRequired: needsRestart(),
    );
  }

  Future<SentryReportingChangeResult> setEnabled(
    bool enabled, {
    bool force = false,
  }) async {
    final previous = state.asData?.value;
    if (previous == null || !previous.configured) {
      return SentryReportingChangeResult.unavailable;
    }
    if (previous.isSaving) return SentryReportingChangeResult.busy;
    if (previous.restartRequired ||
        ref.read(sentryReportingRestartRequiredProvider)()) {
      state = AsyncData(
        SentryReportingPreference(
          enabled: previous.enabled,
          configured: previous.configured,
          restartRequired: true,
        ),
      );
      return SentryReportingChangeResult.restartRequired;
    }
    if (previous.enabled == enabled && !previous.runtimeFailed && !force) {
      return SentryReportingChangeResult.success;
    }
    final store = ref.read(sentryReportingPreferenceStoreProvider);
    final applyOptOut = ref.read(sentryReportingApplyOptOutProvider);
    state = AsyncData(
      SentryReportingPreference(
        enabled: previous.enabled,
        configured: previous.configured,
        isSaving: true,
        runtimeFailed: previous.runtimeFailed,
      ),
    );

    // Save first: a failed disk write must not claim a durable successful choice.
    try {
      await store.writeEnabled(enabled);
    } catch (_) {
      if (ref.mounted) state = AsyncData(previous);
      return SentryReportingChangeResult.persistenceFailed;
    }

    try {
      await applyOptOut(!enabled);
    } on SentryRestartRequiredException {
      if (ref.mounted) {
        state = AsyncData(
          SentryReportingPreference(
            enabled: enabled,
            configured: previous.configured,
            restartRequired: true,
          ),
        );
      }
      return SentryReportingChangeResult.restartRequired;
    } catch (_) {
      // The preference really is saved, but current native state is unconfirmed.
      // Keep this distinction visible and allow retrying the same saved choice.
      if (ref.mounted) {
        state = AsyncData(
          SentryReportingPreference(
            enabled: enabled,
            configured: previous.configured,
            runtimeFailed: true,
          ),
        );
      }
      return SentryReportingChangeResult.runtimeFailed;
    }
    if (ref.mounted) {
      state = AsyncData(
        SentryReportingPreference(
          enabled: enabled,
          configured: previous.configured,
        ),
      );
    }
    return SentryReportingChangeResult.success;
  }
}
