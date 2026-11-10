import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
// Existing plugin boundary, no production dependency added.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/services/xb_apk_downloader.dart';
import 'package:fl_clash/xboard/services/xb_update_probe.dart';
import 'package:fl_clash/xboard/services/xb_update_region.dart';
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';

class _Lookup extends XbUpdateRegionLookup {
  @override
  Future<String?> run() async => null;
}

class _Probe extends XbUpdateSourceProbe {
  final inputs = <List<String>>[];
  Completer<List<String>>? hold;
  bool cancelled = false;
  @override
  Future<List<String>> run(List<String> urls) async {
    inputs.add(List.of(urls));
    return hold == null ? urls.reversed.toList() : await hold!.future;
  }
  @override
  void cancel() { cancelled = true; super.cancel(); }
}

class _Launcher extends UrlLauncherPlatform {
  @override
  Null get linkDelegate => null;
  final urls = <String>[];
  Future<bool> Function(String)? answer;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    urls.add(url);
    expect(options.mode, PreferredLaunchMode.externalApplication);
    return answer == null ? true : await answer!(url);
  }
}

void main() {
  late UrlLauncherPlatform previous;
  late _Launcher launcher;
  setUp(() { previous = UrlLauncherPlatform.instance; launcher = _Launcher(); UrlLauncherPlatform.instance = launcher; });
  tearDown(() { UrlLauncherPlatform.instance = previous; XboardConfig.resetForTest(); });

  Future<void> pump(WidgetTester tester, _Probe probe, {
    bool inApp = false, int count = 3, void Function()? lookupStarted,
    void Function(List<String>)? downloaded,
    Brightness brightness = Brightness.light,
    ValueNotifier<double>? textScale,
    List<String>? urls,
  }) async {
    await tester.pumpWidget(ProviderScope(overrides: [
      xbUpdateRegionLookupFactoryProvider.overrideWithValue(() { lookupStarted?.call(); return _Lookup(); }),
      xbUpdateSourceProbeFactoryProvider.overrideWithValue(() => probe),
      xbInAppUpdateSupportedProvider.overrideWithValue(inApp),
      xbUpdateDownloadProvider.overrideWithValue(({required urls, required onProgress, cancelToken, requestLinuxExit}) async {
        downloaded?.call(urls);
        return DownloadResult.networkError;
      }),
    ], child: MaterialApp(theme: ThemeData(brightness: brightness),
      builder: (context, child) => textScale == null ? child! : ValueListenableBuilder<double>(
        valueListenable: textScale,
        builder: (context, value, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(value)), child: child!),
      ),
      home: Builder(builder: (context) => Scaffold(body: TextButton(
      child: const Text('open'), onPressed: () => showXbUpdateDialog(context,
        AppUpdateModel(versionCode: 99, versionName: 'fixture', region: 'unknown',
          downloads: (urls ?? List.generate(count, (i) => 'https://s$i.invalid/file'))
              .map((url) => AppDownload(url: url, region: 'unknown')).toList(),
          sha256: '', changelog: '', force: false)),
    ))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即更新'));
    await tester.pump();
  }

  for (final brand in ['brand_a', 'brand_b']) {
    for (final width in [320.0, 1100.0]) {
      for (final brightness in Brightness.values) {
      testWidgets('$brand browser fixed order and manual switching width=$width $brightness', (tester) async {
        XboardConfig.bind(XboardConfig(subscribeUserAgent: 'fixture', flavorId: brand,
            devApiEndpoint: 'https://api.invalid', devSubscriptionEndpoint: 'https://sub.invalid', kIsTest: true, debug: false));
        tester.view.physicalSize = Size(width, 800); tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final probe = _Probe();
        var lookups = 0;
        await pump(tester, probe, lookupStarted: () => lookups++, brightness: brightness);
        await tester.pumpAndSettle();
        expect(find.text('重新打开'), findsOneWidget);
        expect(find.textContaining('线路 1/3'), findsOneWidget);
        expect(launcher.urls, ['https://s2.invalid/file']);
        for (final label in ['重新打开','换下一条','换下一条','换下一条']) {
          await tester.tap(find.text(label)); await tester.pumpAndSettle();
        }
        expect(launcher.urls, ['https://s2.invalid/file','https://s2.invalid/file',
            'https://s1.invalid/file','https://s0.invalid/file','https://s2.invalid/file']);
        expect(lookups, 1); expect(probe.inputs.length, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
      }
    }
  }

  for (final throws in [false, true]) {
    testWidgets('launcher failure advances initial source, throw=$throws', (tester) async {
      launcher.answer = (url) async {
        if (url.contains('s2.')) { if (throws) throw StateError('launcher unavailable'); return false; }
        return true;
      };
      await pump(tester, _Probe()); await tester.pumpAndSettle();
      expect(launcher.urls, ['https://s2.invalid/file','https://s1.invalid/file']);
      expect(find.textContaining('线路 2/3'), findsOneWidget);
      expect(find.text('重新打开'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('launcher failure retains controls and one-source next is disabled', (tester) async {
    launcher.answer = (_) async => false;
    await pump(tester, _Probe(), count: 1); await tester.pumpAndSettle();
    expect(find.text('未能打开浏览器，可重试或换线路'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.ancestor(of: find.text('换下一条'), matching: find.byType(FilledButton))).onPressed, isNull);
    await tester.tap(find.text('重新打开')); await tester.pumpAndSettle();
    expect(launcher.urls, ['https://s0.invalid/file','https://s0.invalid/file']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending launcher prevents duplicate open and switch', (tester) async {
    final release = Completer<bool>(); launcher.answer = (_) => release.future;
    await pump(tester, _Probe()); await tester.pump();
    expect(launcher.urls.length, 1);
    expect(tester.widget<OutlinedButton>(find.ancestor(of: find.text('重新打开'), matching: find.byType(OutlinedButton))).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.ancestor(of: find.text('换下一条'), matching: find.byType(FilledButton))).onPressed, isNull);
    release.complete(true); await tester.pumpAndSettle();
    expect(launcher.urls.length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in-app download waits for GET round and receives its frozen order', (tester) async {
    final probe = _Probe()..hold = Completer<List<String>>();
    List<String>? received;
    await pump(tester, probe, inApp: true, downloaded: (urls) => received = urls);
    expect(probe.inputs.length, 1); expect(received, isNull);
    expect(find.text('选择线路中…'), findsOneWidget);
    probe.hold!.complete(['https://s1.invalid/file','https://s0.invalid/file','https://s2.invalid/file']);
    await tester.pumpAndSettle();
    expect(received, ['https://s1.invalid/file','https://s0.invalid/file','https://s2.invalid/file']);
    expect(find.text('下载失败，网络异常'), findsOneWidget);
    expect(launcher.urls, isEmpty);
    await tester.tap(find.text('浏览器下载'));
    await tester.pumpAndSettle();
    expect(probe.inputs.length, 2, reason: 'the browser fallback starts a fresh GET round');
    expect(launcher.urls, ['https://s1.invalid/file']);
    expect(find.text('重新打开'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dispose cancels GET round and late result never opens browser', (tester) async {
    final probe = _Probe()..hold = Completer<List<String>>();
    await pump(tester, probe); expect(probe.inputs.length, 1);
    await tester.pumpWidget(const SizedBox());
    expect(probe.cancelled, isTrue);
    probe.hold!.complete(['https://s0.invalid/file']); await tester.pump();
    expect(launcher.urls, isEmpty); expect(tester.takeException(), isNull);
  });

  testWidgets('browser displays host but never URL path/query/fragment', (tester) async {
    const url = 'https://mirror.invalid/private-file-name?token=fixture-query-token#fixture-fragment';
    await pump(tester, _Probe(), urls: [url]); await tester.pumpAndSettle();
    expect(launcher.urls, [url], reason: 'only display is redacted, not the download address');
    expect(find.textContaining('mirror.invalid'), findsOneWidget);
    for (final secret in ['private-file-name','fixture-query-token','fixture-fragment']) {
      expect(find.textContaining(secret, findRichText: true), findsNothing);
    }
    await tester.pumpWidget(const SizedBox());
  });

  // 1.4 is the production PrismApp cap;1.5/2.0 remain UI_FRAMEWORK stress cases.
  for (final scale in [1.4, 1.5, 2.0]) {
    for (final failed in [false, true]) {
      testWidgets('browser footer supports320 width and text scale$scale, failed=$failed', (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final textScale = ValueNotifier(1.0);
        launcher.answer = (_) async => !failed;
        try {
          await pump(tester, _Probe(), textScale: textScale);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // Change only the new browser state, avoiding unrelated initial UI.
          textScale.value = scale;
          await tester.pumpAndSettle();
          expect(find.text('重新打开'), findsOneWidget);
          expect(find.text('换下一条'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final calls = launcher.urls.length;
          await tester.ensureVisible(find.text('换下一条'));
          await tester.tap(find.text('换下一条'));
          await tester.pumpAndSettle();
          expect(launcher.urls.length, calls + 1);
        } finally {
          await tester.pumpWidget(const SizedBox());
          textScale.dispose();
        }
      }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
    }
  }

  testWidgets('large browser text remains scrollable and actionable in a short window', (tester) async {
    tester.view.physicalSize = const Size(320, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scale = ValueNotifier(1.0);
    try {
      await pump(tester, _Probe(), textScale: scale);
      await tester.pumpAndSettle();
      scale.value = 2.0;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('换下一条'));
      await tester.tap(find.text('换下一条'));
      await tester.pumpAndSettle();
      expect(launcher.urls, ['https://s2.invalid/file','https://s1.invalid/file']);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      scale.dispose();
    }
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
