import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart' as sdk;
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/email_suffixes_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service_impl.dart';
import 'package:fl_clash/xboard/shell/sheets/login_sheet.dart';
import 'package:fl_clash/xboard/shell/sheets/register_sheet.dart';
import '../../../_fixtures/fake_xboard_sdk.dart';

class _Ready extends BootstrapReady {
  @override
  bool build() => true;
}

void main() {
  for (final registration in [false, true]) {
    for (final failed in [false, true]) {
    testWidgets('disposed ${registration ? "registration" : "login"} finishes authentication, failed=$failed', (tester) async {
      final instance = FakeXBoardSDK();
      final api = FakeAuthApi();
      final reply = Completer<sdk.SdkResult<String>>();
      var snapshot = const sdk.AuthSessionSnapshot(revision: 0, state: sdk.AuthState.unauthenticated);
      String? token;
      when(() => instance.auth).thenReturn(api);
      when(() => instance.authSession).thenAnswer((_) => snapshot);
      when(instance.getToken).thenAnswer((_) async => token);
      when(() => api.loginResult(any(), any())).thenAnswer((_) => reply.future);
      when(() => api.registerResult(any(), any(), emailCode: any(named: 'emailCode'),
          inviteCode: any(named: 'inviteCode'))).thenAnswer((_) async => sdk.SdkResult.success(true));
      when(() => instance.saveTokenIfSession(any(), any())).thenAnswer((call) async {
        if (call.positionalArguments[1] != snapshot.revision) return null;
        token = call.positionalArguments[0] as String;
        snapshot = sdk.AuthSessionSnapshot(revision: snapshot.revision + 1, state: sdk.AuthState.authenticated);
        return snapshot;
      });
      final container = ProviderContainer(overrides: [
        bootstrapReadyProvider.overrideWith(() => _Ready()),
        emailSuffixesProvider.overrideWith((_) async => []),
        xboardServiceProvider.overrideWith((_) => XboardServiceImpl(sdk: instance)),
      ]);
      container.read(xboardSdkProvider.notifier).set(instance);
      final initialService = container.read(xboardServiceProvider);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
          onPressed: () => registration ? showRegisterSheet(context) : showLoginSheet(context),
          child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'fixture@example.invalid');
      if (registration) await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.enterText(find.byType(TextField).last, 'fixture-password');
      await tester.tap(find.byType(FilledButton).last);
      await tester.pump();
      verify(() => api.loginResult(any(), any())).called(1);
      Navigator.of(tester.element(find.byType(registration ? RegisterSheet : LoginSheet))).pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byType(registration ? RegisterSheet : LoginSheet), findsNothing);
      if (failed) {
        reply.completeError(StateError('controlled login failure'));
      } else {
        reply.complete(sdk.SdkResult.success('fixture-token'));
      }
      await tester.pumpAndSettle();
      expect(token, failed ? isNull : 'fixture-token');
      expect(container.read(authStateProvider), failed ? AuthState.unauthenticated : AuthState.authenticated);
      if (!failed) {
        expect(identical(container.read(xboardServiceProvider), initialService), isFalse,
            reason: 'new service must bind the saved SDK revision');
      }
      expect(find.text('open'), findsOneWidget, reason: 'late completion must not pop the home route');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    }
  }
}
