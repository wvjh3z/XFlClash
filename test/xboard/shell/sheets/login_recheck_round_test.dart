import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/bootstrap_payload.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
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
  for (final oldFirst in [true, false]) {
    for (final brand in ['brand_a', 'brand_b']) {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        for (final change in ['reopen', 'edit']) {
          testWidgets('$brand $platform recheck $change oldFirst=$oldFirst', (
            t,
          ) async {
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
            final service = a;
            when(() => a.login('demo@example.com', 'password')).thenAnswer(
              (_) async => const XbFailure(
                XbNetwork(XbNetworkKind.connectionFailed, 'fixture'),
              ),
            );
            final probes = [Completer<bool>(), Completer<bool>()];
            var calls = 0;
            final selected = <String>[];
            final race = EndpointRaceController(
              probe: (_) {
                return probes[calls++].future;
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
            if (change == 'reopen') {
              Navigator.of(t.element(find.byType(LoginSheet))).pop();
              await t.pumpAndSettle();
              await t.tap(find.text('open'));
              await t.pumpAndSettle();
              await t.enterText(
                find.byType(TextField).at(0),
                'demo@example.com',
              );
              await t.enterText(find.byType(TextField).at(1), 'password');
              await t.tap(find.text('登录').last);
              await t.pumpAndSettle();
            } else {
              await t.enterText(
                find.byType(TextField).at(0),
                'edited@example.com',
              );
              await t.pump();
            }
            await t.tap(find.text('重新检测'));
            await t.pump();
            expect(calls, 2);
            if (oldFirst) {
              probes[0].complete(true);
              await t.pump();
              expect(selected, isEmpty);
              expect(find.text('检测中…'), findsOneWidget);
              expect(
                t
                    .widget<FilledButton>(find.byType(FilledButton).last)
                    .onPressed,
                isNull,
              );
              probes[1].complete(true);
              await t.pumpAndSettle();
            } else {
              probes[1].complete(true);
              await t.pumpAndSettle();
              probes[0].complete(true);
              await t.pumpAndSettle();
            }
            expect(find.text('线路已更新，请重新登录。'), findsOneWidget);
            expect(selected, ['https://fixture.test']);
            expect(
              t
                  .widget<TextField>(find.byType(TextField).at(0))
                  .controller!
                  .text,
              change == 'edit' ? 'edited@example.com' : 'demo@example.com',
            );
            expect(
              t
                  .widget<TextField>(find.byType(TextField).at(1))
                  .controller!
                  .text,
              'password',
            );
            verify(
              () => a.login('demo@example.com', 'password'),
            ).called(change == 'reopen' ? 2 : 1);
            verifyNever(() => b.login(any(), any()));
            expect(t.takeException(), isNull);
            await t.pumpWidget(const SizedBox());
          });
        }
      }
    }
  }
}
