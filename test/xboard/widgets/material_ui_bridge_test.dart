import 'package:fl_clash/xboard/widgets/xb_ui_kit.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('standalone Material host does not supply legacy localization', (
    tester,
  ) async {
    Object? legacyStrings;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) {
            legacyStrings = Localizations.of<legacy.MaterialLocalizations>(
              context,
              legacy.MaterialLocalizations,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(legacyStrings, isNull);
  });

  for (final name in ['OmoFly', '袋鼠加速']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '$name $brightness bridges legacy HTML locale and typography',
        (tester) async {
          late ThemeData modernTheme;
          late legacy.ThemeData legacyTheme;
          late legacy.MaterialLocalizations legacyStrings;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: XbBrandTheme(
                brandColor: const Color(0xffd92e1a),
                child: Builder(
                  builder: (context) {
                    modernTheme = Theme.of(context);
                    legacyTheme = legacy.Theme.of(context);
                    legacyStrings = legacy.MaterialLocalizations.of(context);
                    return Scaffold(body: Html(data: '<p>$name 套餐 100 GB</p>'));
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(legacyStrings.cancelButtonLabel, '取消');
          expect(legacyTheme.brightness, brightness);
          expect(
            legacyTheme.colorScheme.primary,
            modernTheme.colorScheme.primary,
          );
          expect(
            legacyTheme.textTheme.bodyMedium,
            modernTheme.textTheme.bodyMedium,
          );
          expect(
            find.text('$name 套餐 100 GB', findRichText: true),
            findsWidgets,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
