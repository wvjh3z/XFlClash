import 'dart:async';

import 'package:fl_clash/xboard/shell/widgets/xb_tab_refresh_indicator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '${platform.name}: refresh gesture retained, only Android hides circle',
      (tester) async {
        final done = Completer<void>();
        var calls = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: XbTabRefreshIndicator(
                onRefresh: () {
                  calls++;
                  return done.future;
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 100, child: Text('content')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.drag(find.byType(ListView), const Offset(0, 450));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(calls, 1);
        expect(
          find.byType(RefreshProgressIndicator),
          platform == TargetPlatform.android ? findsNothing : findsOneWidget,
        );
        expect(find.text('content'), findsOneWidget);
        done.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'ordinary Android refresh indicators remain visible outside opted-in tabs',
    (tester) async {
      final done = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: RefreshIndicator(
              onRefresh: () => done.future,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 100, child: Text('other page')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, 450));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      done.complete();
      await tester.pumpAndSettle();
    },
  );
}
