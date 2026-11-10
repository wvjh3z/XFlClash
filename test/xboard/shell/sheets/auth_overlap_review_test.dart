/// Follow-up review: real sheets/service/auth lifecycle with controlled SDK I/O.
library;

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

class _Fixture {
  final instance = FakeXBoardSDK();
  final api = FakeAuthApi();
  final replies = <String, Completer<sdk.SdkResult<String>>>{};
  final requests = <String>[];
  var snapshot = const sdk.AuthSessionSnapshot(revision: 0, state: sdk.AuthState.unauthenticated);
  String? token;
  Future<void> _writes = Future<void>.value();
  final saveStarted = Completer<void>();
  Completer<void>? releaseSaveA;
  late final ProviderContainer container;

  _Fixture() {
    when(() => instance.auth).thenReturn(api);
    when(() => instance.authSession).thenAnswer((_) => snapshot);
    when(instance.getToken).thenAnswer((_) async => token);
    when(() => api.loginResult(any(), any())).thenAnswer((call) {
      final email = call.positionalArguments[0] as String;
      requests.add(email);
      return replies.putIfAbsent(email, Completer<sdk.SdkResult<String>>.new).future;
    });
    when(() => api.registerResult(any(), any(), emailCode: any(named: 'emailCode'),
        inviteCode: any(named: 'inviteCode'))).thenAnswer((_) async => sdk.SdkResult.success(true));
    when(() => instance.saveTokenIfSession(any(), any())).thenAnswer((call) async {
      final previous = _writes;
      final done = Completer<void>();
      _writes = done.future;
      try {
        await previous;
        if (call.positionalArguments[1] != snapshot.revision) return null;
        final value = call.positionalArguments[0] as String;
        if (value == 'fixture-token-a' && releaseSaveA != null) {
          if (!saveStarted.isCompleted) saveStarted.complete();
          await releaseSaveA!.future;
        }
        token = value;
        snapshot = sdk.AuthSessionSnapshot(revision: snapshot.revision + 1,
            state: sdk.AuthState.authenticated);
        return snapshot;
      } finally {
        done.complete();
      }
    });
    when(() => instance.clearTokenIfSession(any())).thenAnswer((call) async {
      final previous = _writes;
      final done = Completer<void>();
      _writes = done.future;
      try {
        await previous;
        if (call.positionalArguments[0] != snapshot.revision) return false;
        token = null;
        snapshot = sdk.AuthSessionSnapshot(revision: snapshot.revision + 1,
            state: sdk.AuthState.unauthenticated);
        return true;
      } finally {
        done.complete();
      }
    });
    container = ProviderContainer(overrides: [
      bootstrapReadyProvider.overrideWith(() => _Ready()),
      emailSuffixesProvider.overrideWith((_) async => []),
      xboardServiceProvider.overrideWith((_) => XboardServiceImpl(sdk: instance)),
    ]);
    container.read(xboardSdkProvider.notifier).set(instance);
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => showLoginSheet(context), child: const Text('open')))))));
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String email) async {
    await tester.enterText(find.byType(TextField).at(0), email);
    if (find.byType(TextField).evaluate().length == 3) {
      await tester.enterText(find.byType(TextField).at(1), '123456');
    }
    await tester.enterText(find.byType(TextField).last, 'fixture-password');
    await tester.tap(find.byType(FilledButton).last);
    await tester.pump();
  }

  Future<void> dismiss(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(LoginSheet))).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(LoginSheet), findsNothing);
  }

  void succeed(String email, String value) => replies[email]!.complete(sdk.SdkResult.success(value));
}

void main() {
  for (final olderFirst in [true, false]) {
  testWidgets('overlapping login sheets remain recoverable, olderFirst=$olderFirst', (tester) async {
    final f = _Fixture();
    try {
      await f.pump(tester);
      await f.open(tester);
      await f.submit(tester, 'a@example.invalid');
      await f.dismiss(tester);
      await f.open(tester);
      await f.submit(tester, 'b@example.invalid');
      expect(f.requests, ['a@example.invalid', 'b@example.invalid']);
      if (olderFirst) {
        f.succeed('a@example.invalid', 'fixture-token-a');
        await tester.pump();
        f.succeed('b@example.invalid', 'fixture-token-b');
      } else {
        f.succeed('b@example.invalid', 'fixture-token-b');
        await tester.pump();
        f.succeed('a@example.invalid', 'fixture-token-a');
      }
      await tester.pumpAndSettle();
      // If B was not established, a new explicit attempt must still reach SDK.
      if (f.container.read(authStateProvider) != AuthState.authenticated) {
        await f.submit(tester, 'c@example.invalid');
        expect(f.requests, contains('c@example.invalid'),
            reason: 'a saved but unowned SDK revision must not permanently stale the service');
        f.succeed('c@example.invalid', 'fixture-token-c');
        await tester.pumpAndSettle();
      }
      expect(f.container.read(authStateProvider), AuthState.authenticated);
      expect(f.token, isNot('fixture-token-a'), reason: 'superseded A must not become the final account');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      f.container.dispose();
    }
  });
  }

  testWidgets('superseded in-progress token save is cleaned and explicit retry works', (tester) async {
    final f = _Fixture()..releaseSaveA = Completer<void>();
    try {
      await f.pump(tester);
      await f.open(tester);
      await f.submit(tester, 'a@example.invalid');
      f.succeed('a@example.invalid', 'fixture-token-a');
      await tester.pump();
      expect(f.saveStarted.isCompleted, isTrue);
      await f.dismiss(tester);
      await f.open(tester);
      await f.submit(tester, 'b@example.invalid');
      f.succeed('b@example.invalid', 'fixture-token-b');
      await tester.pump();
      f.releaseSaveA!.complete();
      await tester.pumpAndSettle();
      expect(f.token, isNot('fixture-token-a'));
      if (f.container.read(authStateProvider) != AuthState.authenticated) {
        await f.submit(tester, 'c@example.invalid');
        expect(f.requests, contains('c@example.invalid'));
        f.succeed('c@example.invalid', 'fixture-token-c');
        await tester.pumpAndSettle();
      }
      expect(f.container.read(authStateProvider), AuthState.authenticated);
      expect(f.token, anyOf('fixture-token-b', 'fixture-token-c'));
      expect(tester.takeException(), isNull);
    } finally {
      if (!f.releaseSaveA!.isCompleted) f.releaseSaveA!.complete();
      await tester.pumpWidget(const SizedBox());
      f.container.dispose();
    }
  });

  for (final width in [390.0, 1100.0]) {
  testWidgets('login reverse animation preserves the next sheet, width=$width', (tester) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final f = _Fixture();
    try {
      await f.pump(tester);
      await f.open(tester);
      await f.submit(tester, 'a@example.invalid');
      // Production footer pops LoginSheet and immediately opens RegisterSheet.
      await tester.tap(find.text('注册账号'));
      await tester.pump();
      expect(find.byType(LoginSheet, skipOffstage: false), findsOneWidget,
          reason: 'the test must resolve while the outgoing sheet is still mounted');
      expect(find.byType(RegisterSheet), findsOneWidget);
      f.succeed('a@example.invalid', 'fixture-token-a');
      await tester.pumpAndSettle();
      expect(f.container.read(authStateProvider), AuthState.authenticated);
      expect(find.byType(RegisterSheet), findsOneWidget,
          reason: 'a closing login route cannot pop the newly opened registration route');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      f.container.dispose();
    }
  });

  testWidgets('registration login reverse animation preserves the next sheet, width=$width', (tester) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final f = _Fixture();
    try {
      await f.pump(tester);
      await f.open(tester);
      await tester.tap(find.text('注册账号'));
      await tester.pumpAndSettle();
      await f.submit(tester, 'a@example.invalid');
      expect(f.requests, ['a@example.invalid']);
      final context = tester.element(find.byType(RegisterSheet));
      Navigator.of(context).pop();
      unawaited(showLoginSheet(context));
      await tester.pump();
      expect(find.byType(RegisterSheet, skipOffstage: false), findsOneWidget);
      expect(find.byType(LoginSheet), findsOneWidget);
      f.succeed('a@example.invalid', 'fixture-token-a');
      await tester.pumpAndSettle();
      expect(f.container.read(authStateProvider), AuthState.authenticated);
      expect(find.byType(LoginSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      f.container.dispose();
    }
  });
  }
}
