import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/services/endpoint_race_controller.dart';
import 'package:fl_clash/xboard/shell/sheets/login_sheet.dart';

class Service extends Mock implements XboardService {}

class Ready extends BootstrapReady {
  @override
  bool build() => true;
  void pending() => state = false;
}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final change in [
        'success',
        'failure',
        'timeout',
        'bootstrap',
        'authrebuild',
        'email',
        'password',
        'service',
        'auth',
        'race',
        'dispose',
        'pop',
        'barrier',
        'register',
        'forgot',
      ]) {
        testWidgets('$brand $platform recheck $change', (t) async {
          XboardConfig.bind(
            XboardConfig(
              appName: brand,
              flavorId: brand,
              subscribeUserAgent: 'fixture',
              devApiEndpoint: '',
              devSubscriptionEndpoint: '',
              debug: true,
              kIsTest: true,
              formA: true,
            ),
          );
          addTearDown(XboardConfig.resetForTest);
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(
            platform == TargetPlatform.android ? 390 : 1100,
            1000,
          );
          addTearDown(t.view.reset);
          final a = Service(), b = Service();
          XboardService service = a;
          when(() => a.login('demo@example.com', 'password')).thenAnswer(
            (_) async => const XbFailure(
              XbNetwork(XbNetworkKind.connectionFailed, 'fixture'),
            ),
          );
          final probe = Completer<bool>();
          var calls = 0;
          final selected = <String>[];
          final race = EndpointRaceController(
            probe: (_) {
              calls++;
              return probe.future;
            },
            onApiSwitch: selected.add,
          );
          race.seedEndpoints([
            const BootstrapEndpoint(url: 'https://fixture.test'),
          ], []);
          addTearDown(race.dispose);
          final c = ProviderContainer(
            overrides: [
              bootstrapReadyProvider.overrideWith(Ready.new),
              xboardServiceProvider.overrideWith((_) => service),
            ],
          );
          addTearDown(c.dispose);
          c.read(injectedRaceControllerProvider.notifier).set(race);
          await t.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: MaterialApp(
                theme: ThemeData(platform: platform),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => showLoginSheet(context),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.tap(find.text('open'));
          await t.pumpAndSettle();
          await t.enterText(find.byType(TextField).at(0), 'demo@example.com');
          await t.enterText(find.byType(TextField).at(1), 'password');
          await t.tap(find.text('登录').last);
          await t.pumpAndSettle();
          final action = t
              .widget<TextButton>(
                find.ancestor(
                  of: find.text('重新检测'),
                  matching: find.byType(TextButton),
                ),
              )
              .onPressed!;
          action();
          action();
          await t.pump();
          expect(calls, 1);
          expect(
            t.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
            isNull,
          );
          if (change == 'email') {
            await t.enterText(find.byType(TextField).at(0), 'new@example.com');
          }
          if (change == 'password') {
            await t.enterText(find.byType(TextField).at(1), 'newpassword');
          }
          if (change == 'service') {
            service = b;
            c.invalidate(xboardServiceProvider);
            await t.pump();
          }
          if (change == 'bootstrap') {
            (c.read(bootstrapReadyProvider.notifier) as Ready).pending();
            await t.pump();
          }
          if (change == 'authrebuild') {
            final before = c.read(authStateProvider.notifier);
            c.invalidate(authStateProvider);
            await t.pump();
            expect(
              identical(before, c.read(authStateProvider.notifier)),
              isTrue,
            );
          }
          if (change == 'auth') {
            c.read(authStateProvider.notifier).markAuthenticated();
          }
          if (change == 'race') {
            c
                .read(injectedRaceControllerProvider.notifier)
                .set(EndpointRaceController(probe: (_) async => false));
            await t.pump();
          }
          final closing = [
            'pop',
            'barrier',
            'register',
            'forgot',
          ].contains(change);
          if (change == 'pop') {
            Navigator.of(t.element(find.byType(LoginSheet))).pop();
          }
          if (change == 'barrier') {
            await t.tapAt(const Offset(5, 50));
          }
          if (change == 'register' || change == 'forgot') {
            await t.tap(find.text(change == 'register' ? '注册账号' : '忘记密码？'));
          }
          if (closing) {
            await t.pump();
            // Verify the vulnerable reverse-animation window, not disposal.
            expect(
              find.byType(LoginSheet, skipOffstage: false),
              findsOneWidget,
            );
          }
          if (change == 'dispose') await t.pumpWidget(const SizedBox());
          if (change == 'timeout') await t.pump(const Duration(seconds: 11));
          probe.complete(change != 'failure');
          await t.pumpAndSettle();
          if (change == 'success' || change == 'authrebuild') {
            expect(find.text('线路已更新，请重新登录。'), findsOneWidget);
            expect(selected, ['https://fixture.test']);
          } else {
            expect(find.text('线路已更新，请重新登录。'), findsNothing);
            expect(selected, isEmpty);
          }
          if (change == 'failure' || change == 'timeout') {
            expect(find.textContaining('暂未找到'), findsOneWidget);
          }
          if (change != 'dispose' && !closing) {
            expect(
              t
                  .widget<TextField>(find.byType(TextField).at(0))
                  .controller!
                  .text,
              change == 'email' ? 'new@example.com' : 'demo@example.com',
            );
            expect(
              t
                  .widget<TextField>(find.byType(TextField).at(1))
                  .controller!
                  .text,
              change == 'password' ? 'newpassword' : 'password',
            );
          }
          verify(() => a.login('demo@example.com', 'password')).called(1);
          verifyNever(() => b.login(any(), any()));
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
