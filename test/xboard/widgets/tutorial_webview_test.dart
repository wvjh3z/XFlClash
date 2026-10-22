import 'dart:io';

import 'package:fl_clash/xboard/widgets/tutorial_webview.dart';
import 'package:fl_clash/xboard/services/xboard_release_dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'com.pichillilorenzo/flutter_webview_environment',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late InAppWebViewPlatform? oldPlatform;
  late List<String> calls;
  late _TestWebViewPlatform platform;

  setUp(() {
    oldPlatform = InAppWebViewPlatform.instance;
    platform = _TestWebViewPlatform();
    InAppWebViewPlatform.instance = platform;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    // The public platform API does not allow resetting an initial null value.
    if (oldPlatform != null) InAppWebViewPlatform.instance = oldPlatform;
  });

  Future<void> pumpReader(WidgetTester tester, String html) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TutorialWebView(
          html: html,
          resourceBase: Uri.parse('https://docs.example.invalid/'),
          articleUrl: Uri.parse('https://docs.example.invalid/#/docs/21'),
          onOpenTutorial: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets(
    'Windows缺运行时有官方下载和外部阅读入口，不创建原生视图',
    (tester) async {
      await pumpReader(tester, '<p>教程</p>');
      expect(calls, ['getAvailableVersion']);
      expect(find.text('下载 WebView2'), findsOneWidget);
      expect(find.text('在浏览器中查看'), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Windows正文过大在原生调用前提供外部阅读入口',
    (tester) async {
      await pumpReader(tester, '正文' * (1024 * 1024));
      expect(calls, isEmpty);
      expect(find.text('教程正文较大，请在浏览器中查看。'), findsOneWidget);
      expect(find.text('在浏览器中查看'), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Android/macOS reader forwards the global certificate policy to native trust challenges',
    (tester) async {
      await pumpReader(
        tester,
        '<p>教程<img src="https://self-signed.invalid/image"></p>',
      );
      expect(find.byType(InAppWebView), findsOneWidget);
      final params = platform.views.single.params;
      final controller = InAppWebViewController.fromPlatform(
        platform: _TestWebViewController(),
      );
      final trust = params.onReceivedServerTrustAuthRequest;
      expect(trust, isNotNull);
      expect(XboardReleaseHttp.allowBadCertificate, isTrue);
      for (final host in ['docs.example.invalid', 'self-signed.invalid']) {
        final response = await trust!(
          controller,
          ServerTrustChallenge(
            protectionSpace: URLProtectionSpace(
              host: host,
              protocol: 'https',
              port: 443,
            ),
          ),
        );
        expect(response?.action, ServerTrustAuthResponseAction.PROCEED);
      }
      expect(params.initialSettings?.cacheEnabled, isFalse);
      expect(params.initialSettings?.domStorageEnabled, isFalse);
      expect(params.onReceivedError, isNotNull);
      expect(params.shouldOverrideUrlLoading, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final stale = await trust!(
        controller,
        ServerTrustChallenge(
          protectionSpace: URLProtectionSpace(host: 'self-signed.invalid'),
        ),
      );
      expect(stale?.action, ServerTrustAuthResponseAction.CANCEL);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.macOS,
    }),
  );

  testWidgets(
    'Windows reader passes global certificate policy to its actual WebView2 environment',
    (tester) async {
      final cache = await tester.runAsync(
        () => Directory.systemTemp.createTemp('tutorial-tls-settings-'),
      );
      Map? createdSettings;
      var disposed = false;
      String? environmentId;
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(paths, (call) async {
        expect(call.method, 'getApplicationCacheDirectory');
        return cache!.path;
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'getAvailableVersion') return '123.0.0.0';
        expect(call.method, 'create');
        final args = call.arguments as Map;
        environmentId = args['id'] as String;
        messenger.setMockMethodCallHandler(
          MethodChannel(
            'com.pichillilorenzo/flutter_webview_environment_$environmentId',
          ),
          (call) async {
            expect(call.method, 'dispose');
            disposed = true;
            return null;
          },
        );
        createdSettings = args['settings'] as Map;
        return true;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(paths, null);
        if (environmentId != null) {
          messenger.setMockMethodCallHandler(
            MethodChannel(
              'com.pichillilorenzo/flutter_webview_environment_$environmentId',
            ),
            null,
          );
        }
        if (await cache!.exists()) await cache.delete(recursive: true);
      });

      await pumpReader(tester, '<p>教程</p>');
      // Native-channel continuations use the test zone while filesystem I/O
      // completes in the real event loop; advance both without native rendering.
      for (
        var attempt = 0;
        attempt < 1000 && createdSettings == null;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump();
      }
      expect(createdSettings, isNotNull);
      final settings = createdSettings!;
      await tester.pump();
      expect(calls, ['getAvailableVersion', 'create']);
      expect(
        settings['additionalBrowserArguments'],
        '--ignore-certificate-errors',
      );
      expect(settings['userDataFolder'], startsWith(cache!.path));
      expect(platform.views, hasLength(1));
      final environment = platform.views.single.params.webViewEnvironment;
      expect(
        environment?.settings?.additionalBrowserArguments,
        '--ignore-certificate-errors',
      );
      expect(environment?.settings?.userDataFolder, settings['userDataFolder']);
      expect(find.byType(InAppWebView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final profile = Directory(settings['userDataFolder'] as String);
      for (
        var attempt = 0;
        attempt < 1000 && (!disposed || profile.existsSync());
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump();
      }
      expect(disposed, isTrue);
      expect(profile.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

class _TestWebViewPlatform extends InAppWebViewPlatform {
  final views = <_TestWebViewWidget>[];
  final windows = WindowsInAppWebViewPlatform();

  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironment(
    PlatformWebViewEnvironmentCreationParams params,
  ) => windows.createPlatformWebViewEnvironment(params);

  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      windows.createPlatformWebViewEnvironmentStatic();

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _TestWebViewWidget(params);
    views.add(view);
    return view;
  }
}

class _TestWebViewWidget extends PlatformInAppWebViewWidget {
  _TestWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  void dispose() {}
}

class _TestWebViewController extends PlatformInAppWebViewController {
  _TestWebViewController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'test'),
      );
}
