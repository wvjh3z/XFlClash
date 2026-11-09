import 'dart:ui' show SemanticsAction;

import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_ui_compatibility.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart';

// Known upstream gaps, explicitly deferred by the user. Keep the desired
// assertions as opt-in diagnostics, not inverted assertions that bless a bug.
const _verifyUpstreamSemantics = bool.fromEnvironment(
  'XB_VERIFY_UPSTREAM_PRISM_SEMANTICS',
);
const _deferredReason = 'Known upstream Prism semantics gap; user deferred. '
    'Use --dart-define=XB_VERIFY_UPSTREAM_PRISM_SEMANTICS=true to reproduce.';

Widget _host(Widget child) => prism.PrismApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.delegate.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate, AppUiLocalizations.delegate,
    ...material.GlobalMaterialLocalizations.delegates,
  ],
  builder: (_, child) => XbUiCompatibilityHost(child: child!),
  home: Directionality(textDirection: TextDirection.ltr, child: child),
);

void main() {
  for (final semantic in [false, true]) {
    testWidgets('checkbox activation via ${semantic ? 'semantics' : 'pointer'}'
        '${semantic && !_verifyUpstreamSemantics ? ' ($_deferredReason)' : ''}',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
      var checked = false;
      var changes = 0;
      await tester.pumpWidget(_host(Center(child: StatefulBuilder(
        builder: (_, setState) => Semantics(label: 'filter-toggle',
          child: prism.Checkbox(value: checked,
            onChanged: (value) => setState(() {
              changes++;
              checked = value!;
            }))),
      ))));
      await tester.pumpAndSettle();
      if (semantic) {
        final node = tester.getSemantics(find.bySemanticsLabel('filter-toggle'));
        final advertised = node.getSemanticsData().hasAction(SemanticsAction.tap);
        tester.binding.renderViews.single.owner!.semanticsOwner!
            .performAction(node.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        debugPrint('checkbox semantics: advertised=$advertised changed=$checked');
        expect(checked, isTrue, reason: 'A semantics tap must toggle the checkbox');
        expect(advertised, isTrue);
      } else {
        await tester.tap(find.byType(prism.Checkbox));
        await tester.pumpAndSettle();
        expect(checked, isTrue);
      }
      expect(changes, 1, reason: 'one activation must not fire twice');
      } finally {
        semantics.dispose();
      }
    }, skip: semantic && !_verifyUpstreamSemantics);
    testWidgets('Android more activation via ${semantic ? 'semantics' : 'pointer'}'
        '${semantic && !_verifyUpstreamSemantics ? ' ($_deferredReason)' : ''}',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
      tester.view.physicalSize = const Size(180, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController(text: 'alpha beta');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(Center(child: SizedBox(width: 160,
        child: prism.TextField(controller: controller)))));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(prism.TextField));
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(find.byType(prism.TextField));
      await tester.pumpAndSettle();
      expect(find.text('Select all'), findsNothing);
      if (semantic) {
        final node = tester.getSemantics(find.bySemanticsLabel('More'));
        final advertised = node.getSemanticsData().hasAction(SemanticsAction.tap);
        tester.binding.renderViews.single.owner!.semanticsOwner!
            .performAction(node.id, SemanticsAction.tap);
        tester.binding.renderViews.single.owner!.semanticsOwner!
            .performAction(node.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        debugPrint('more semantics: advertised=$advertised expanded=${find.text('Select all').evaluate().isNotEmpty}');
        expect(find.text('Select all'), findsOneWidget);
        expect(advertised, isTrue);
      } else {
        await tester.tap(find.byWidgetPredicate((w) =>
          w is GlyphIcon && w.glyph == Glyphs.chevronForward));
        await tester.pumpAndSettle();
        expect(find.text('Select all'), findsOneWidget);
      }
      } finally {
        semantics.dispose();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.android),
       skip: semantic && !_verifyUpstreamSemantics);
  }

  testWidgets('disabled checkbox exposes no semantic tap', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_host(Center(child: Semantics(
        label: 'disabled-filter',
        child: const prism.Checkbox(value: false, onChanged: null),
      ))));
      await tester.pumpAndSettle();
      final node = tester.getSemantics(find.bySemanticsLabel('disabled-filter'));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('mixed checkbox semantics produces one checked value'
      '${!_verifyUpstreamSemantics ? ' ($_deferredReason)' : ''}', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final changes = <bool?>[];
      await tester.pumpWidget(_host(Center(child: Semantics(
        label: 'mixed-filter',
        child: prism.Checkbox(value: null, onChanged: changes.add),
      ))));
      await tester.pumpAndSettle();
      final node = tester.getSemantics(find.bySemanticsLabel('mixed-filter'));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.binding.renderViews.single.owner!.semanticsOwner!
          .performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(changes, [true]);
    } finally {
      semantics.dispose();
    }
  }, skip: !_verifyUpstreamSemantics);

  testWidgets('keyboard enter and space each toggle exactly once', (tester) async {
    var checked = false;
    var changes = 0;
    await tester.pumpWidget(_host(Center(child: StatefulBuilder(
      builder: (_, setState) => prism.Checkbox(value: checked,
        onChanged: (value) => setState(() { checked = value!; changes++; })),
    ))));
    await tester.pumpAndSettle();
    final gesture = find.descendant(of: find.byType(prism.Checkbox),
        matching: find.byType(GestureDetector));
    Focus.of(tester.element(gesture)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(changes, 1);
    expect(checked, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(changes, 2);
    expect(checked, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
