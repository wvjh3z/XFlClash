import 'dart:async';

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
    final action = find.byType(XbGroupDelayAction).first;
    final originalSize = tester.getSize(action);
    expect(originalSize, const Size(44, 44));
    expect(find.text('测延迟'), findsOneWidget); // Desktop remains a text action.
    await tester.tap(action);
    await tester.pump();
    adapter.progress['A']!(2, 3);
    await tester.pump();
    expect(find.text('2/3'), findsNothing);
    expect(tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator)).value, isNull);
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
    expect(find.byTooltip('B · 测速中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    update(() => selected = a);
    await tester.pump();
    expect(find.byTooltip('A · 测速中'), findsOneWidget);
    expect(tester.getSize(action), originalSize);

    adapter.pending['A']!.complete();
    await tester.pump();
    expect(find.text('60s'), findsOneWidget);
    expect(find.text('测延迟 60s'), findsOneWidget); // Already-mounted desktop observes cooldown.
    await tester.tap(action);
    await tester.pump();
    expect(adapter.calls, 2);
    update(() => selected = b);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget); // Own running state wins over cooldown.
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
  });
}
