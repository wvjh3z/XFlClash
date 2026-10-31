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
