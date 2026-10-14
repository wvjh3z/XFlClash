import 'package:fl_clash/xboard/widgets/tutorial_webview.dart';
import 'package:flutter/material.dart';
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

  setUp(() {
    oldPlatform = InAppWebViewPlatform.instance;
    WindowsInAppWebViewPlatform.registerWith();
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
}
