import 'package:fl_clash/xboard/widgets/xb_components.dart';
import 'package:fl_clash/xboard/widgets/xb_feedback.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

LinearGradient? _fill(WidgetTester tester, String label) {
  final decoration = find.ancestor(of: find.text(label), matching: find.byWidgetPredicate(
    (w) => w is DecoratedBox && w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).gradient is LinearGradient,
  ));
  if (decoration.evaluate().isEmpty) return null;
  return (tester.widget<DecoratedBox>(decoration.first).decoration as BoxDecoration)
      .gradient as LinearGradient;
}

void main() {
  for (final brand in [const Color(0xffd92e1a), const Color(0xff4573a8)]) {
    testWidgets('icon primary inherits $brand; outlined and disabled actions do not', (t) async {
      var count = 0;
      Future<void> draw(bool enabled) => t.pumpWidget(MaterialApp(
        theme: buildXbTheme(brandColor: brand, brightness: Brightness.dark),
        home: Scaffold(body: XbEmptyState(icon: Icons.public, title: '线路',
          actionLabel: '购买套餐', actionIcon: Icons.store, onAction: enabled ? () => count++ : null,
          secondaryLabel: '刷新', onSecondary: () => count += 10)),
      ));
      await draw(true);
      final fill = _fill(t, '购买套餐')!;
      expect(fill.colors.last, brand);
      if (brand == const Color(0xffd92e1a)) {
        expect(fill.colors.first, const Color(0xffff5a44));
      } else {
        expect(fill.colors.first, isNot(const Color(0xffff5a44)));
      }
      expect(_fill(t, '刷新'), isNull);
      await t.tap(find.text('购买套餐'));
      await t.tap(find.text('刷新'));
      expect(count, 11);
      await draw(false);
      expect(_fill(t, '购买套餐'), isNull);
      await t.tap(find.text('购买套餐'));
      expect(count, 11);
    });
  }

  testWidgets('confirm uses brand only for non-destructive actions', (t) async {
    late BuildContext host;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      host = context;
      return const Scaffold();
    })));
    for (final danger in [false, true]) {
      final answer = xbConfirm(host, title: '操作', message: '请确认', destructive: danger);
      await t.pumpAndSettle();
      expect(_fill(t, '取消'), isNull);
      expect(_fill(t, '确定') != null, !danger);
      if (danger) {
        final button = t.widget<FilledButton>(find.widgetWithText(FilledButton, '确定'));
        expect(button.style!.backgroundColor!.resolve({}), XbTokens.bad);
      }
      await t.tap(find.text(danger ? '取消' : '确定'));
      await t.pumpAndSettle();
      expect(await answer, !danger);
    }
  });

  testWidgets('bottom action keeps its icon, tap and loading lock', (t) async {
    var calls = 0;
    Future<void> draw(bool loading) => t.pumpWidget(MaterialApp(
      theme: buildXbTheme(brandColor: const Color(0xffd92e1a), brightness: Brightness.light),
      home: Scaffold(
      bottomNavigationBar: XbBottomActionBar(primaryLabel: '提交订单', primaryIcon: Icons.check,
        primaryLoading: loading, onPrimary: () => calls++, secondaryLabel: '返回'),
    )));
    await draw(false);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byType(XbGradientAction), findsOneWidget);
    expect(_fill(t, '提交订单'), isNotNull);
    await t.tap(find.text('提交订单'));
    await draw(true);
    const busy = '正在创建订单…';
    expect(_fill(t, busy), isNull);
    expect(find.text('提交订单'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.check), findsNothing);
    final button = t.widget<FilledButton>(find.widgetWithText(FilledButton, busy));
    expect(button.onPressed, isNull);
    expect(button.style!.backgroundColor!.resolve({WidgetState.disabled}), const Color(0xffd7857d));
    expect(t.widget<Text>(find.text(busy)).style!.color, Colors.white);
    await t.tap(find.text(busy));
    expect(calls, 1);
  });
  testWidgets('busyLabel wins over a live callback and permits large text to wrap', (t) async {
    var calls = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(
        width: 120,
        child: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: XbGradientAction(
            busyLabel: '正在核对余额和流水…',
            onPressed: () => calls++,
            child: const Icon(Icons.check),
          ),
        ),
      ))),
    ));
    final label = find.text('正在核对余额和流水…');
    expect(t.getSize(label).height, greaterThan(28));
    expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await t.tap(label);
    expect(calls, 0);
    expect(t.takeException(), isNull);
  });
}
