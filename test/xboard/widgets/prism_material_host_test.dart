import 'dart:async';

import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/ui/qr_code.dart';
import 'package:fl_clash/xboard/shell/adapters/xb_ui_compatibility.dart';
import 'package:fl_clash/xboard/widgets/xb_theme.dart';
import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/widgets.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:prism_ui/prism_ui.dart' as prism;

Widget host({
  required Widget child,
  required Brightness brightness,
  required Locale locale,
  required GlobalKey<NavigatorState> navigator,
  bool bridge = true,
}) => prism.PrismApp(
  navigatorKey: navigator,
  theme: prism.ThemeData(brightness: Brightness.light),
  darkTheme: prism.ThemeData(brightness: Brightness.dark),
  themeMode: brightness == Brightness.dark
      ? prism.ThemeMode.dark
      : prism.ThemeMode.light,
  locale: locale,
  supportedLocales: AppLocalizations.delegate.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    AppUiLocalizations.delegate,
    ...material.GlobalMaterialLocalizations.delegates,
  ],
  builder: (_, navigator) => bridge
      ? XbUiCompatibilityHost(child: navigator!)
      : navigator!,
  home: child,
);

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows,
    TargetPlatform.linux, TargetPlatform.macOS]) {
  for (final brand in {
    'brand_a': const Color(0xff2468c0),
    'brand_b': const Color(0xffd92e1a),
  }.entries) {
    for (final brightness in Brightness.values) {
      for (final locale in const [
        Locale('zh', 'CN'), Locale('en'), Locale('ja'), Locale('ru'),
      ]) {
        testWidgets('$platform ${brand.key} $brightness $locale has mixed UI route scopes',
            (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
          final navigator = GlobalKey<NavigatorState>();
          var pushed = false;
          Widget destination() => Builder(builder: (context) {
            pushed = true;
            final brandTheme = material.Theme.of(context);
            expect(brandTheme.brightness, brightness);
            expect(brandTheme.colorScheme.primary, brand.value);
            expect(brandTheme.scaffoldBackgroundColor,
                brightness == Brightness.dark ? const Color(0xff0a0c11) : const Color(0xfff5f6f8));
            expect(brandTheme.textTheme.bodyMedium?.color,
                brightness == Brightness.dark ? const Color(0xfff1f3f8) : const Color(0xff11141b));
            expect(brandTheme.textTheme.bodyMedium?.fontSize, 14);
            expect(legacy.Theme.of(context).colorScheme.primary, brand.value);
            expect(legacy.Theme.of(context).textTheme.bodyMedium,
                brandTheme.textTheme.bodyMedium);
            expect(prism.Theme.of(context).brightness, brightness);
            expect(Navigator.of(context), same(navigator.currentState));
            expect(material.MaterialLocalizations.of(context).cancelButtonLabel,
                isNotEmpty);
            expect(legacy.MaterialLocalizations.of(context).cancelButtonLabel,
                isNotEmpty);
            expect(prism.UiLocalizations.of(context).cancel, isNotEmpty);
            return material.Scaffold(
              body: Column(children: [
                Html(data: '<p>brand-content</p>'),
                const QrCodeView(data: 'https://example.invalid/pay'),
                material.TextButton(
                  onPressed: () => material.ScaffoldMessenger.of(context)
                      .showSnackBar(const material.SnackBar(
                        content: material.Text('copy-ok'),
                      )),
                  child: const material.Text('copy'),
                ),
              ]),
            );
          });
          await tester.pumpWidget(host(
            brightness: brightness,
            locale: locale,
            navigator: navigator,
            child: XbBrandTheme(
              brandColor: brand.value,
              child: Builder(builder: (context) => material.Scaffold(
                body: material.TextButton(
                  onPressed: () => unawaited(xbPush<void>(
                    context, destination(), brandColor: brand.value, replace: true,
                  )),
                  child: const material.Text('open'),
                ),
              )),
            ),
          ));
          await tester.pumpAndSettle();
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          expect(pushed, isTrue);
          final expectedBackground = brightness == Brightness.dark
              ? const Color(0xff0a0c11) : const Color(0xfff5f6f8);
          expect(tester.widgetList<material.Material>(find.byType(material.Material))
              .any((surface) => surface.color == expectedBackground), isTrue);
          expect(find.text('brand-content', findRichText: true), findsWidgets);
          await tester.tap(find.text('copy'));
          await tester.pump();
          expect(find.text('copy-ok'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }
  }
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('$platform open brand route follows light-dark-light changes', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final brightness = ValueNotifier(Brightness.light);
      final navigator = GlobalKey<NavigatorState>();
      final observed = <List<Brightness>>[];
      const brandColor = Color(0xffd92e1a);
      try {
        final destination = Builder(builder: (context) {
          final current = material.Theme.of(context).brightness;
          observed.add([current, legacy.Theme.of(context).brightness,
            prism.Theme.of(context).brightness]);
          return const material.Scaffold(body: Text('theme-change-destination'));
        });
        await tester.pumpWidget(ValueListenableBuilder<Brightness>(
          valueListenable: brightness,
          builder: (_, value, _) => host(
            brightness: value,
            locale: const Locale('en'),
            navigator: navigator,
            child: XbBrandTheme(
              brandColor: brandColor,
              child: Builder(builder: (context) => material.Scaffold(
                body: material.TextButton(
                  onPressed: () => unawaited(xbPush<void>(context, destination,
                      brandColor: brandColor, replace: true)),
                  child: const Text('open-dynamic-theme'),
                ),
              )),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('open-dynamic-theme'));
        await tester.pumpAndSettle();
        for (final value in [Brightness.light, Brightness.dark, Brightness.light]) {
          brightness.value = value;
          await tester.pumpAndSettle();
          expect(observed.last, [value, value, value]);
          final expected = value == Brightness.dark
              ? const Color(0xff0a0c11) : const Color(0xfff5f6f8);
          expect(tester.widgetList<material.Material>(find.byType(material.Material))
              .any((surface) => surface.color == expected), isTrue);
          expect(find.text('theme-change-destination'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        brightness.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('without the host, Prism does not provide Material messenger',
      (tester) async {
    var checked = false;
    await tester.pumpWidget(host(
      brightness: Brightness.dark,
      locale: const Locale('en'),
      navigator: GlobalKey<NavigatorState>(),
      bridge: false,
      child: Builder(builder: (context) {
        checked = true;
        expect(prism.Theme.of(context).brightness, Brightness.dark);
        expect(material.ScaffoldMessenger.maybeOf(context), isNull);
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();
    expect(checked, isTrue);
    expect(tester.takeException(), isNull);
  });
}
