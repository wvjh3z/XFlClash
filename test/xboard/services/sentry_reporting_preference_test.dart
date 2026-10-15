import 'package:fl_clash/xboard/services/sentry_reporting_preference.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockPreferences extends Mock implements SharedPreferences {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'existing installations default to enabled; explicit opt-out persists',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = SentryReportingPreferenceStore();
      expect(await store.readEnabled(), isTrue);
      await store.writeEnabled(false);
      expect(await SentryReportingPreferenceStore().readEnabled(), isFalse);
      await store.writeEnabled(true);
      expect(await SentryReportingPreferenceStore().readEnabled(), isTrue);
    },
  );

  test(
    'false platform write is a failure and refreshes the preferences cache',
    () async {
      final preferences = MockPreferences();
      when(
        () => preferences.setBool(kSentryReportingEnabledKey, false),
      ).thenAnswer((_) async => false);
      when(preferences.reload).thenAnswer((_) async {});
      final store = SentryReportingPreferenceStore(
        preferences: () async => preferences,
      );
      await expectLater(store.writeEnabled(false), throwsStateError);
      verify(preferences.reload).called(1);
    },
  );

  test(
    'throwing platform write is a failure even if cache refresh fails',
    () async {
      final preferences = MockPreferences();
      when(
        () => preferences.setBool(kSentryReportingEnabledKey, false),
      ).thenThrow(StateError('platform failure'));
      when(preferences.reload).thenThrow(StateError('reload failure'));
      final store = SentryReportingPreferenceStore(
        preferences: () async => preferences,
      );
      await expectLater(store.writeEnabled(false), throwsStateError);
    },
  );
}
