import 'dart:async';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
// Existing plugin boundary, no production dependency added.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/providers/xboard_connectivity_provider.dart';
import '../../_fixtures/fake_connectivity.dart';
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
    XbUpdateDownload? download,
    FakeConnectivity? connectivity,
    Brightness brightness = Brightness.light,
    ValueNotifier<double>? textScale,
    List<String>? urls,
  }) async {
    final links = connectivity ?? FakeConnectivity();
    if (connectivity == null) addTearDown(links.close);
    await tester.pumpWidget(ProviderScope(overrides: [
      xboardConnectivityClientProvider.overrideWithValue(links),
      xbUpdateRegionLookupFactoryProvider.overrideWithValue(() { lookupStarted?.call(); return _Lookup(); }),
      xbUpdateSourceProbeFactoryProvider.overrideWithValue(() => probe),
      xbInAppUpdateSupportedProvider.overrideWithValue(inApp),
      xbUpdateDownloadProvider.overrideWithValue(download ?? ({required urls, required onProgress, cancelToken, requestLinuxExit}) async {
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
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '重新打开')).onPressed, isNull);
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

  for (final brightness in Brightness.values) {
    testWidgets('download progress stays legible at 320dp and large text ($brightness)', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final scale = ValueNotifier(1.0);
      final done = Completer<DownloadResult>();
      try {
        // The small percentage leaves the text over the unfilled track.
        // The larger sample puts it over the gradient.
        final pct = brightness == Brightness.light ? 5 : 65;
        await pump(tester, _Probe(), inApp: true, brightness: brightness,
          textScale: scale, download: ({required urls, required onProgress, cancelToken, requestLinuxExit}) {
            onProgress(pct * 1024 * 1024, 100 * 1024 * 1024);
            return done.future;
          },
        );
        await tester.pumpAndSettle();
        final labels = find.text('$pct%');
        expect(labels, findsNWidgets(2));
        final fill = find.byWidgetPredicate((w) => w is FractionallySizedBox &&
            w.widthFactor == pct / 100 && w.child is DecoratedBox);
        final fillWidget = tester.widget<FractionallySizedBox>(fill);
        final decoration = (fillWidget.child! as DecoratedBox).decoration as BoxDecoration;
        final gradient = decoration.gradient! as LinearGradient;
        expect(decoration.borderRadius, BorderRadius.circular(18));
        expect(gradient.begin, Alignment.centerLeft);
        expect(gradient.end, Alignment.centerRight);
        final track = find.ancestor(of: fill, matching: find.byWidgetPredicate(
          (w) => w is Container && w.constraints?.minHeight == 36,
        ));
        expect(tester.getSize(track).height, 36);
        final styles = tester.widgetList<Text>(labels).map((w) => w.style!);
        expect(styles.first.color, Theme.of(tester.element(fill)).colorScheme.onSurface);
        expect(styles.last.color, Colors.white);
        expect(styles.last.shadows?.single.blurRadius, 4);
        scale.value = 2;
        await tester.pumpAndSettle();
        expect(tester.getSize(track).height, greaterThanOrEqualTo(tester.getSize(labels.first).height));
        expect(find.text('正在下载 · $pct.0 / 100.0 MB'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        done.complete(DownloadResult.networkError);
        await tester.pumpWidget(const SizedBox());
        scale.dispose();
      }
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
  }

  testWidgets('dispose cancels GET round and late result never opens browser', (tester) async {
    final probe = _Probe()..hold = Completer<List<String>>();
    await pump(tester, probe); expect(probe.inputs.length, 1);
    await tester.pumpWidget(const SizedBox());
    expect(probe.cancelled, isTrue);
    probe.hold!.complete(['https://s0.invalid/file']); await tester.pump();
    expect(launcher.urls, isEmpty); expect(tester.takeException(), isNull);
  });

  for (final offline in [true, false]) {
    testWidgets('下载中切网停止，恢复不自动下载，蜂窝确认后重新开始 offline=$offline', (tester) async {
      final links = FakeConnectivity();
      addTearDown(links.close);
      final results = <Completer<DownloadResult>>[];
      late bool Function() cancelled;
      await pump(tester, _Probe(), inApp: true, connectivity: links,
          download: ({required urls, required onProgress, cancelToken, requestLinuxExit}) {
            cancelled = () => cancelToken!.isCancelled;
            final done = Completer<DownloadResult>();
            results.add(done);
            onProgress(1024 * 1024, -1);
            return done.future;
          });
      if (offline) { links.goOffline(); } else { links.goMobile(); }
      await tester.pump();
      expect(cancelled(), isTrue);
      results.single.complete(DownloadResult.networkError);
      await tester.pumpAndSettle();
      expect(find.textContaining('将从头下载'), findsOneWidget);
      links.goMobile();
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('使用蜂窝网络下载'), findsOneWidget);
      expect(results, hasLength(1));
      await tester.tap(find.text('使用蜂窝网络下载'));
      await tester.pump();
      expect(results, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      results.last.complete(DownloadResult.networkError);
      await tester.pump();
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('unknown download size, retry isolation and final sample ($brightness)', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final scale = ValueNotifier(1.0);
      final callbacks = <DownloadProgress>[];
      final results = <Completer<DownloadResult>>[];
      final cancelled = <bool Function()>[];
      const mib = 1024 * 1024;
      try {
        await pump(tester, _Probe(), inApp: true, brightness: brightness, textScale: scale,
          download: ({required urls, required onProgress, cancelToken, requestLinuxExit}) {
            callbacks.add(onProgress);
            cancelled.add(() => cancelToken!.isCancelled);
            final result = Completer<DownloadResult>();
            results.add(result);
            return result.future;
          },
        );
        callbacks.single(0, -1);
        scale.value = 1.4;
        await tester.pump();
        expect(find.text('正在准备下载…'), findsOneWidget);
        callbacks.single(100, 0);
        await tester.pump();
        expect(find.textContaining('已接收 100 B'), findsOneWidget);
        callbacks.single(1024, -1);
        await tester.pump();
        expect(find.textContaining('已接收 1.0 KiB'), findsOneWidget);
        callbacks.single(5 * mib, -1);
        await tester.pump(const Duration(milliseconds: 101));
        expect(find.textContaining('已接收 5.0 MiB（总大小未知）'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.textContaining('%'), findsNothing);
        expect(find.text('正在准备下载…'), findsNothing);

        results.single.complete(DownloadResult.networkError);
        await tester.pumpAndSettle();
        await tester.tap(find.text('重试'));
        await tester.pump();
        expect(callbacks, hasLength(2));
        callbacks.first(9 * mib, 10 * mib); // 上次请求的迟到回调。
        await tester.pump();
        expect(find.text('正在准备下载…'), findsOneWidget);
        expect(find.textContaining('已接收'), findsNothing);
        callbacks.last(0, 10 * mib);
        await tester.pump();
        expect(find.text('0%'), findsNWidgets(2));
        callbacks.last(mib, 10 * mib);
        callbacks.last(10 * mib, 10 * mib);
        await tester.pump();
        expect(find.text('100%'), findsNWidgets(2));
        expect(find.text('正在下载 · 10.0 / 10.0 MB'), findsOneWidget);
        if (brightness == Brightness.dark) {
          // 无 Content-Length 的新镜像也只能依据真实成功结果结束下载。
          callbacks.last(5 * mib, -1);
          await tester.pump();
          results.last.complete(DownloadResult.success);
          await tester.pump();
          await tester.pump();
          expect(find.text('下载完成，已交给安装程序'), findsOneWidget);
          expect(find.textContaining('%'), findsNothing);
          // 非 Linux 主机还会等待系统安装器唤起后再收起弹窗。
          await tester.pump(const Duration(milliseconds: 501));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (results.length == 2 && !results.last.isCompleted) {
          expect(cancelled.last(), isTrue);
          callbacks.last(1, -1);
        }
        for (final result in results) {
          if (!result.isCompleted) result.complete(DownloadResult.networkError);
        }
        await tester.pump();
        scale.dispose();
      }
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
  }

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
          if (scale == 1.4) {
            for (final label in ['重新打开', '换下一条']) {
              final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
              final boxes = paragraph.getBoxesForSelection(TextSelection(
                baseOffset: 0, extentOffset: label.length,
              ));
              expect(boxes.map((box) => box.top).toSet(), hasLength(1),
                  reason: '$label should fit on one line at 320dp / 1.4');
            }
          }
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
