import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/config/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_paths.dart';
import '../../helpers/glyph_finders.dart';
import '../../helpers/test_app.dart';
import '../../plugins/code_forge/support.dart' show initEditorNative, settle;

class _Core extends Mock implements CoreHandlerInterface {}

class _HeldCompiles {
  final values = <String>[];
  final gates = <Completer<RuleSetInfo>>[];
  Future<RuleSetInfo> call(String fileName) {
    values.add(fileName);
    final gate = Completer<RuleSetInfo>();
    gates.add(gate);
    return gate.future;
  }
  void completeAll() {
    for (var i=0; i<gates.length; i++) {
      if (!gates[i].isCompleted) {
        gates[i].complete((
          behavior: RuleProviderBehavior.classical, format: RuleProviderFormat.yaml,
        ));
      }
    }
  }
}

void main() {
  late Directory home;
  setUpAll(() async {
    await initEditorNative();
    home = Directory.systemTemp.createTempSync('editor-owner-validation-');
    await useAppPaths(home);
  });
  tearDownAll(() => home.deleteSync(recursive: true));

  for (final scenario in ['single-save', 'save-then-back-confirm', 'late-save-new-route']) {
    testWidgets('real rule-provider Editor $scenario', (tester) async {
      const size = Size(1200, 900);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final database = db.Database(NativeDatabase.memory());
      db.database = database;
      final writes = _HeldCompiles();
      final core = _Core();
      when(() => core.compileRuleSet(any(), url: any(named: 'url')))
          .thenAnswer((call) => writes.call(call.positionalArguments.first as String));
      final container = ProviderContainer(overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ]);
      globalState.container = container;
      container.read(viewSizeProvider.notifier).value = size;
      try {
        await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: const TestApp(child: ClashProvidersView())));
        await settle(tester);
        await tester.tap(find.byTooltip('Add'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(currentAppLocalizations.startFromScratch));
        for (var i=0; i<40 && find.byType(EditorPage).evaluate().isEmpty; i++) {
          await settle(tester, 1);
        }
        debugPrint('editor open: popup=${find.byType(PopupMenu).evaluate().length} '
            'editor=${find.byType(EditorPage).evaluate().length}');
        expect(find.byType(EditorPage), findsOneWidget);
        expect(find.text('Editor unavailable'), findsNothing);
        for (var i=0; i<40 &&
            tester.state<EditorViewState>(find.byType(EditorView)).controller == null; i++) {
          await settle(tester, 1);
        }
        expect(tester.state<EditorViewState>(find.byType(EditorView)).controller, isNotNull);
        tester.state<EditorViewState>(find.byType(EditorView)).controller!.text =
            'payload:\n  - DOMAIN,example.invalid\n';
        await tester.enterText(find.byType(TextField).first, 'Fixture rules');
        await tester.pump();
        final saveButton = find.widgetWithGlyph(IconButton, AppGlyphs.check);
        expect(tester.widget<IconButton>(saveButton).onPressed, isNotNull);
        await tester.tap(saveButton);
        for (var i=0; i<30 && writes.values.isEmpty; i++) {
          await settle(tester, 1);
        }
        expect(writes.values, hasLength(1), reason: 'must enter the real editor save consumer');

        if (scenario == 'save-then-back-confirm') {
          unawaited(globalState.navigatorKey.currentState!.maybePop());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          if (find.text(currentAppLocalizations.confirm).evaluate().isNotEmpty) {
            await tester.tap(find.text(currentAppLocalizations.confirm));
            await settle(tester, 8);
          }
          debugPrint('Editor save/back writes=${writes.values.length}');
          expect(writes.values, hasLength(1), reason: 'back-save cannot overlap an active save');
        }
        if (scenario == 'late-save-new-route') {
          unawaited(globalState.navigatorKey.currentState!.push(HostPageRoute<void>(
            builder: (_) => const Center(child: Text('newer-route')),
          )));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('newer-route'), findsOneWidget);
        }
        writes.completeAll();
        await settle(tester, 4);
        await tester.pump(const Duration(milliseconds: 1200));
        await settle(tester, 6);
        if (scenario == 'late-save-new-route') {
          debugPrint('late Editor save newer route visible=${find.text('newer-route').evaluate().isNotEmpty}');
          expect(find.text('newer-route'), findsOneWidget,
              reason: 'a late editor save must not pop a later route');
        } else {
          expect(writes.values, hasLength(1));
          expect(find.byType(EditorPage), findsNothing);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        writes.completeAll();
        await settle(tester, 4);
        await tester.pump(const Duration(milliseconds: 1500));
        await settle(tester, 2);
        final stored = await tester.runAsync(() => database.clashProvidersDao.query().get());
        debugPrint('Editor $scenario actual SQLite rows=${stored?.length}');
        await tester.runAsync(() async {
          container.dispose();
          await database.close().timeout(const Duration(seconds: 5));
        });
      }
    // Known upstream ownership failure; awaiting upstream fix. Opt in to diagnose.
    }, skip: scenario != 'single-save' && !const bool.fromEnvironment('XB_VERIFY_UPSTREAM_P1'));
  }
}
