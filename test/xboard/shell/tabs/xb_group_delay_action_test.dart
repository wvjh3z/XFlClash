import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/tabs/nodes/xb_group_delay_action.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart';

class TestAdapter extends XbNodesAdapter {
  final pending = <String, Completer<void>>{};
  final progress = <String, void Function(int, int)?>{};
  int calls = 0;

  @override
  Future<void> testGroupDelay(
    WidgetRef ref,
    String groupName, {
    void Function(int done, int total)? onProgress,
  }) {
    calls++;
    progress[groupName] = onProgress;
    return (pending[groupName] = Completer<void>()).future;
  }
}

XbGroupSummary group(String name, int count) => XbGroupSummary(
  name: name,
  nodeCount: count,
  currentSelected: '',
  isUrlTest: false,
  kind: XbGroupKind.selector,
  nodes: List.generate(count, (i) => XbNodeItem(name: '$name-$i', type: 'ss')),
);

void main() {
  testWidgets('toolbar owns per-group progress, shared cooldown and late completion', (tester) async {
    final adapter = TestAdapter();
    final a = group('A', 3);
    final b = group('B', 120);
    var selected = a;
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(ProviderScope(
      overrides: [xbNodesAdapterProvider.overrideWithValue(adapter)],
      child: MaterialApp(
        theme: buildXbTheme(brandColor: Colors.red, brightness: Brightness.light),
        home: Scaffold(body: StatefulBuilder(builder: (_, setState) {
          update = setState;
          return Row(children: [
            if (visible) XbGroupDelayAction(group: selected, compact: true),
            XbGroupDelayAction(key: const ValueKey('desktop'), group: group('desktop', 2)),
          ]);
        })),
      ),
    ));
    final semantics = tester.ensureSemantics();
    try {
    final action = find.byType(XbGroupDelayAction).first;
    Finder visibleLabel(String text) => find.descendant(
      of: action,
      matching: find.text(text),
    );
    bool advertisesAction(String label) => tester
        .getSemantics(find.bySemanticsLabel(label))
        .getSemanticsData()
        .hasAction(SemanticsAction.tap);
    final originalSize = tester.getSize(action);
    expect(originalSize, const Size(76, 44));
    expect(visibleLabel('测延迟'), findsOneWidget);
    expect(find.text('测延迟'), findsNWidgets(2)); // Desktop stays text too.
    expect(advertisesAction('A · 测延迟'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focusOutline = find.descendant(
      of: action,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.position == DecorationPosition.foreground &&
            (widget.decoration as BoxDecoration).border != null,
      ),
    );
    expect(focusOutline, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(adapter.calls, 1);
    adapter.progress['A']!(2, 3);
    await tester.pump();
    expect(visibleLabel('测速中'), findsOneWidget);
    expect(advertisesAction('A · 测速中'), isTrue); // Tap reports progress.
    expect(find.text('2/3'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(action);
    await tester.pump();
    expect(adapter.calls, 1); // Progress tap reports status, never restarts.

    update(() => selected = b);
    await tester.pump();
    await tester.tap(action);
    await tester.pump();
    adapter.progress['B']!(60, 120);
    await tester.pump();
    expect(find.text('50%'), findsNothing);
    expect(advertisesAction('B · 测速中'), isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    update(() => selected = a);
    await tester.pump();
    expect(advertisesAction('A · 测速中'), isTrue);
    expect(tester.getSize(action), originalSize);

    final desktop = find.byKey(const ValueKey('desktop'));
    await tester.tap(find.descendant(of: desktop, matching: find.byType(TextButton)));
    adapter.progress['desktop']!(1, 2);
    await tester.pump();
    expect(find.text('测速中 1/2'), findsOneWidget);
    expect(tester.widget<TextButton>(
      find.descendant(of: desktop, matching: find.byType(TextButton)),
    ).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    adapter.pending['desktop']!.complete();
    adapter.pending['A']!.complete();
    await tester.pump();
    expect(find.text('60s'), findsOneWidget);
    expect(visibleLabel('冷却'), findsOneWidget);
    expect(visibleLabel('测延迟'), findsNothing);
    expect(advertisesAction('A · 测速冷却 60 秒'), isTrue);
    expect(tester.getSize(action), originalSize);
    expect(find.text('测延迟 60s'), findsOneWidget); // Already-mounted desktop observes cooldown.
    await tester.tap(action);
    await tester.pump();
    expect(adapter.calls, 3);
    update(() => selected = b);
    await tester.pump();
    expect(visibleLabel('测速中'), findsOneWidget); // Own running state wins over cooldown.
    update(() => visible = false);
    await tester.pump();
    adapter.pending['B']!.completeError(StateError('late failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    update(() { visible = true; selected = a; });
    await tester.pump();
    expect(find.text('60s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // No live timer/listener after disposal.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

}
