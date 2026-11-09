import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:fl_clash/xboard/services/xb_update_region.dart';
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';

class DelayedLookup extends XbUpdateRegionLookup {
  final result = Completer<String?>();
  bool cancelled = false;
  @override
  Future<String?> run() => result.future;
  @override
  void cancel() {
    cancelled = true;
    if (!result.isCompleted) result.complete(null);
    super.cancel();
  }
}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final force in [false, true]) {
      for (final phase in ['initial', 'selecting', 'failed']) {
        testWidgets('D11 $brand force=$force back during $phase', (tester) async {
          final lookup = DelayedLookup();
          await tester.pumpWidget(ProviderScope(
            overrides: [xbUpdateRegionLookupFactoryProvider.overrideWithValue(() => lookup)],
            child: MaterialApp(home: Builder(builder: (context) => Scaffold(
              body: TextButton(onPressed: () => showXbUpdateDialog(context,
                AppUpdateModel(versionCode: 999, versionName: 'fixture', region: 'unknown',
                  downloads: [], sha256: '', changelog: '', force: force)),
                child: const Text('open'))))),
          ));
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          if (phase != 'initial') {
            await tester.tap(find.text('立即更新'));
            await tester.pump();
            expect(find.text('选择线路中…'), findsOneWidget);
          }
          if (phase == 'failed') {
            lookup.result.complete(null);
            await tester.pumpAndSettle();
            expect(find.text('无法打开下载链接，请重试'), findsOneWidget);
          }
          await tester.binding.handlePopRoute();
          if (phase == 'selecting') {
            await tester.pump(const Duration(milliseconds: 300));
          } else {
            await tester.pumpAndSettle();
          }
          if (phase == 'selecting') {
            expect(find.text('选择线路中…'), findsOneWidget);
            lookup.result.complete(null);
            await tester.pumpAndSettle();
          } else {
            expect(find.text('立即更新'), findsNothing);
            expect(find.text('重试'), findsNothing);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
      }
    }

    testWidgets(
      '$brand selecting is single line, retry starts fresh, dispose cancels',
      (tester) async {
        // Narrow layout test; Linux splash avoids shader assets in no-assets VM.
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final probes = <DelayedLookup>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              xbUpdateRegionLookupFactoryProvider.overrideWithValue(() {
                final probe = DelayedLookup();
                probes.add(probe);
                return probe;
              }),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showXbUpdateDialog(
                      context,
                      const AppUpdateModel(
                        versionCode: 36,
                        versionName: '0.0.1',
                        region: 'cn',
                        downloads: [],
                        sha256: '',
                        changelog: '',
                        force: false,
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('立即更新'));
        await tester.pump();
        expect(probes.length, 1);
        final text = tester.widget<Text>(find.text('选择线路中…'));
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
        probes.single.result.complete('CN');
        await tester.pumpAndSettle();
        expect(find.text('无法打开下载链接，请重试'), findsOneWidget);
        await tester.tap(find.text('重试'));
        await tester.pump();
        expect(probes.length, 2);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(probes.last.cancelled, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({TargetPlatform.linux}),
    );
  }
}
