import 'dart:ui' show SemanticsAction;

import 'package:emoji_regex/emoji_regex.dart';
import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_group_tabs.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_nodes_adapter.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_ui_compatibility.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:prism_ui/prism_ui.dart' as prism;

XbGroupSummary group(String name) => XbGroupSummary(
  name: name,
  nodeCount: 0,
  currentSelected: '',
  isUrlTest: false,
  kind: XbGroupKind.selector,
  nodes: const [],
);

class Fixture {
  Fixture(int count)
    : groups = List.generate(count, (i) => group('🇭🇰 分组 ${i + 1}'));
  List<XbGroupSummary> groups;
  String? selection;
  bool visible = true;
  int targetNonce = 0;
  int outsideCalls = 0;
  final calls = <String>[];
  final navigator = GlobalKey<NavigatorState>();
  late StateSetter update;
}

Future<Fixture> pumpGroups(
  WidgetTester tester, {
  int count = 12,
  double width = 390,
  Brightness brightness = Brightness.light,
  bool outsideAction = false,
  bool trailing = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  final fixture = Fixture(count);
  await tester.pumpWidget(
    prism.PrismApp(
      navigatorKey: fixture.navigator,
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.delegate.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        AppUiLocalizations.delegate,
        ...material.GlobalMaterialLocalizations.delegates,
      ],
      theme: prism.ThemeData(brightness: brightness),
      emojiFont: (family: 'Twemoji', pattern: emojiRegex()),
      builder: (_, child) => XbUiCompatibilityHost(child: child!),
      home: material.Scaffold(
        body: StatefulBuilder(
          builder: (_, setState) {
            fixture.update = setState;
            if (!fixture.visible) return const Text('owner removed');
            final content = XbGroupTabs(
              groups: fixture.groups,
              selected: fixture.selection ?? fixture.groups.first.name,
              targetNonce: fixture.targetNonce,
              headerBuilder: trailing
                  ? (_, group) => SizedBox(height: 44, child: Text('action:${group.name}'))
                  : null,
              header: const SizedBox(
                height: 56,
                child: Center(child: Text('group header')),
              ),
              onSelected: (name) {
                fixture.calls.add(name);
                setState(() => fixture.selection = name);
              },
              groupBuilder: (_, group) =>
                  Center(child: Text('content:${group.name}')),
            );
            return Column(
              children: [
                Expanded(child: trailing
                    ? material.Theme(
                        data: buildXbTheme(brandColor: const Color(0xffd92e1a), brightness: brightness),
                        child: content,
                      )
                    : content),
                if (outsideAction)
                  material.TextButton(
                    onPressed: () => fixture.outsideCalls++,
                    child: const Text('outside action'),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byType(prism.IconButton));
  await tester.pump();
  expect(find.byType(prism.PopupMenu), findsOneWidget);
}

Future<void> pickLast(WidgetTester tester, Fixture fixture) async {
  final item = find.descendant(
    of: find.byType(prism.PopupMenu),
    matching: find.text(fixture.groups.last.name, findRichText: true),
  );
  final scroll = find.descendant(
    of: find.byType(prism.PopupMenu),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(item, 180, scrollable: scroll);
  // The native menu intentionally exposes half a row and has an elastic
  // release. Existence/partial visibility is not a valid tap target yet.
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  final visible = tester.getRect(item).intersect(tester.getRect(scroll));
  expect(visible.height, greaterThanOrEqualTo(tester.getSize(item).height - 1));
  await tester.tap(item);
}

void main() {
  testWidgets('header action follows selected group without crowding the overflow menu', (tester) async {
    final fixture = await pumpGroups(tester, width: 360, trailing: true);
    final chipContext = tester.element(find.byType(prism.Card).first);
    expect(prism.Theme.of(chipContext).colorScheme.surfaceBright,
        material.Theme.of(chipContext).colorScheme.surfaceContainerLow);
    expect(find.text('action:${fixture.groups.first.name}'), findsOneWidget);
    await openMenu(tester);
    await pickLast(tester, fixture);
    await tester.pumpAndSettle();
    expect(find.text('action:${fixture.groups.last.name}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  setUp(() {
    final original = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = original);
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name}: native popup opens, returns, selects once and reveals Emoji tab',
      (tester) async {
        final fixture = await pumpGroups(tester, brightness: brightness);
        await openMenu(tester);
        final route = ModalRoute.of(
          tester.element(find.byType(prism.PopupMenu)),
        )!;
        expect(route.transitionDuration, greaterThan(Duration.zero));
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          route.animation!.value,
          lessThan(1),
          reason: 'Opening is not replaced by a static menu',
        );
        await tester.pumpAndSettle();
        final menu = tester.widget<prism.PopupMenu>(
          find.byType(prism.PopupMenu),
        );
        expect(menu.maxVisibleItems, 7);
        expect(menu.items.length, 12);
        expect(
          menu.items.where((item) => item.checked == true).single.label,
          fixture.groups.first.name,
        );
        expect(
          find.descendant(
            of: find.byType(prism.PopupMenu),
            matching: find.byType(prism.EmojiText),
          ),
          findsWidgets,
        );
        await pickLast(tester, fixture);
        await tester.pump();
        expect(
          fixture.calls,
          isEmpty,
          reason: 'Selection waits for the native return animation',
        );
        await tester.pumpAndSettle();
        expect(fixture.calls, [fixture.groups.last.name]);
        expect(find.byType(prism.PopupMenu), findsNothing);
        expect(
          find.text('content:${fixture.groups.last.name}'),
          findsOneWidget,
        );
        final tab = find.text(fixture.groups.last.name, findRichText: true);
        expect(tab, findsOneWidget);
        final bounds = tester.getRect(tab);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(390));
        expect(fixture.navigator.currentState!.canPop(), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('No overflow has no arrow or popup', (tester) async {
    await pumpGroups(tester, count: 2, width: 800);
    expect(find.byType(prism.IconButton), findsNothing);
    expect(find.byType(prism.PopupAnchor), findsNothing);
    expect(find.byType(prism.PopupMenu), findsNothing);
  });

  testWidgets('Back closes local menu without leaving owner', (tester) async {
    final fixture = await pumpGroups(tester);
    await openMenu(tester);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(prism.PopupMenu), findsNothing);
    expect(find.byType(XbGroupTabs), findsOneWidget);
    expect(fixture.calls, isEmpty);
  });

  testWidgets(
    'Outside tap dismisses menu without activating the shell action',
    (tester) async {
      final fixture = await pumpGroups(tester, outsideAction: true);
      await openMenu(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('outside action'));
      await tester.pumpAndSettle();
      expect(find.byType(prism.PopupMenu), findsNothing);
      expect(fixture.outsideCalls, 0);
      await tester.tap(find.text('outside action'));
      await tester.pumpAndSettle();
      expect(fixture.outsideCalls, 1);
    },
  );

  for (final activations in [1, 2]) {
    testWidgets(
      'Menu activation $activations times cannot pop the local content page',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final fixture = await pumpGroups(tester);
          await openMenu(tester);
          await tester.pumpAndSettle();
          final name = fixture.groups[1].name;
          final label = find.descendant(
            of: find.byType(prism.PopupMenu),
            matching: find.text(name, findRichText: true),
          );
          final item = find.ancestor(
            of: label,
            matching: find.byType(prism.PressRegion),
          );
          final node = tester.getSemantics(item.first);
          expect(
            node.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
            reason:
                'The negative control must invoke the actionable row, not its text leaf',
          );
          final owner =
              tester.binding.renderViews.single.owner!.semanticsOwner!;
          for (var i = 0; i < activations; i++) {
            owner.performAction(node.id, SemanticsAction.tap);
          }
          await tester.pumpAndSettle();
          expect(fixture.calls, [name]);
          expect(find.text('content:$name'), findsOneWidget);
          expect(find.byType(XbGroupTabs), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  for (final removeOwner in [false, true]) {
    testWidgets(
      'Deferred pick is ignored after ${removeOwner ? 'owner removal' : 'group replacement'}',
      (tester) async {
        final fixture = await pumpGroups(tester);
        await openMenu(tester);
        await tester.pumpAndSettle();
        await pickLast(tester, fixture);
        await tester.pump();
        expect(fixture.calls, isEmpty);
        fixture.update(() {
          if (removeOwner) {
            fixture.visible = false;
          } else {
            fixture.groups = [group('🇯🇵 新分组')];
            fixture.selection = fixture.groups.first.name;
          }
        });
        await tester.pumpAndSettle();
        expect(fixture.calls, isEmpty);
        expect(find.byType(prism.PopupMenu), findsNothing);
        expect(
          find.text(removeOwner ? 'owner removed' : 'content:🇯🇵 新分组'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('External group target closes old menu and follows the new tab', (
    tester,
  ) async {
    final fixture = await pumpGroups(tester);
    await openMenu(tester);
    await tester.pumpAndSettle();
    fixture.update(() => fixture.selection = fixture.groups.last.name);
    await tester.pumpAndSettle();
    expect(find.byType(prism.PopupMenu), findsNothing);
    expect(find.text('content:${fixture.groups.last.name}'), findsOneWidget);
    expect(
      fixture.calls,
      isEmpty,
      reason: 'External target is not a second user action',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Native page swipe keeps the selected group in sync', (
    tester,
  ) async {
    final fixture = await pumpGroups(tester, count: 3);
    await tester.drag(find.byType(prism.TabBarView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(fixture.selection, fixture.groups[1].name);
    expect(find.text('content:${fixture.groups[1].name}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Repeated external target closes menu even when group is unchanged',
    (tester) async {
      final fixture = await pumpGroups(tester);
      await openMenu(tester);
      await tester.pumpAndSettle();
      fixture.update(() => fixture.targetNonce++);
      await tester.pumpAndSettle();
      expect(find.byType(prism.PopupMenu), findsNothing);
      expect(fixture.calls, isEmpty);
      expect(find.text('content:${fixture.groups.first.name}'), findsOneWidget);
    },
  );
}
