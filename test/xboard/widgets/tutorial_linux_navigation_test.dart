import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_html/flutter_html.dart';
// Existing url_launcher platform boundary; test-only, no new production dependency.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/widgets/tutorial_webview.dart';
import 'package:fl_clash/xboard/widgets/tutorial_html_fallback.dart';
import 'package:fl_clash/xboard/util/tutorial_html.dart';

class _Launcher extends UrlLauncherPlatform {
  @override
  Null get linkDelegate => null;
  final urls = <String>[];
  bool fail = false;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    if (fail) throw StateError('launcher failed');
    urls.add(url);
    return true;
  }
}

void main() {
  late UrlLauncherPlatform previous;
  late _Launcher launcher;
  setUp(() {
    previous = UrlLauncherPlatform.instance;
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
  });
  tearDown(() {
    UrlLauncherPlatform.instance = previous;
    XboardConfig.resetForTest();
  });
  final base = Uri.parse('https://docs.example.invalid/');
  Future<void> reader(
    WidgetTester tester,
    String body,
    Future<void> Function(int) open,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TutorialWebView(
            html: buildTutorialHtml(body, resourceBase: base, isDark: false),
            resourceBase: base,
            articleUrl: base.replace(fragment: '/docs/21'),
            onOpenTutorial: open,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void bind(String brand) => XboardConfig.bind(
    XboardConfig(
      subscribeUserAgent: 'test',
      devApiEndpoint: 'https://api.example.invalid',
      devSubscriptionEndpoint: 'https://sub.example.invalid',
      debug: false,
      kIsTest: true,
      flavorId: brand,
      formA: true,
    ),
  );
  for (final brand in ['brand_a', 'brand_b']) {
    testWidgets('$brand Linux jump buttons and links use the reader dispatcher', (
      tester,
    ) async {
      bind(brand);
      final opened = <int>[];
      await reader(
        tester,
        '<button onclick="jump(22)">下一篇</button><button onclick="jump(0)">无效</button><a href="/#/docs/23">内部</a>',
        (id) async {
          opened.add(id);
        },
      );
      await tester.tap(find.text('下一篇'));
      await tester.pump();
      expect(opened, [22]);
      final html = tester.widget<Html>(find.byType(Html));
      html.onLinkTap!('/#/docs/23', {}, null);
      await tester.pump();
      expect(opened, [22, 23]);
      final badButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('无效'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(badButton.onPressed, isNull);
      html.onLinkTap!('downloads/client.deb', {}, null);
      await tester.pump();
      html.onLinkTap!('https://other.example.invalid/#/docs/24', {}, null);
      await tester.pump();
      expect(launcher.urls, [
        'https://docs.example.invalid/downloads/client.deb',
        'https://other.example.invalid/#/docs/24',
      ]);
      html.onLinkTap!('javascript:alert(1)', {}, null);
      html.onLinkTap!(
        'https://user:password@docs.example.invalid/#/docs/25',
        {},
        null,
      );
      await tester.pump();
      expect(launcher.urls, hasLength(2));
      expect(opened, [22, 23]);
      launcher.fail = true;
      final fallback = tester.widget<TutorialHtmlFallback>(
        find.byType(TutorialHtmlFallback),
      );
      expect(
        await fallback.onOpenLink('https://other.example.invalid/fail'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets(
      '$brand Linux replaced and disposed document callbacks are inert',
      (tester) async {
        bind(brand);
        final first = <int>[];
        final second = <int>[];
        await reader(tester, '<button onclick="jump(22)">旧教程</button>', (
          id,
        ) async {
          first.add(id);
        });
        final oldLink = tester
            .widget<TutorialHtmlFallback>(find.byType(TutorialHtmlFallback))
            .onOpenLink;
        final oldButton = tester
            .widget<OutlinedButton>(find.byType(OutlinedButton))
            .onPressed!;
        await reader(tester, '<button onclick="jump(33)">新教程</button>', (
          id,
        ) async {
          second.add(id);
        });
        oldButton();
        expect(await oldLink('/#/docs/22'), isFalse);
        expect(await oldLink('https://other.example.invalid/old'), isFalse);
        await tester.pump();
        expect(first, isEmpty);
        expect(second, isEmpty);
        expect(launcher.urls, isEmpty);
        await tester.tap(find.text('新教程'));
        await tester.pump();
        expect(second, [33]);
        final current = tester
            .widget<TutorialHtmlFallback>(find.byType(TutorialHtmlFallback))
            .onOpenLink;
        await tester.pumpWidget(const SizedBox.shrink());
        expect(await current('/#/docs/34'), isFalse);
        expect(
          await current('https://other.example.invalid/disposed'),
          isFalse,
        );
        expect(second, [33]);
        expect(launcher.urls, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets(
      '$brand Linux late navigation result and failed callback do not survive replacement',
      (tester) async {
        bind(brand);
        final done = Completer<void>();
        await reader(tester, '<p>旧内容</p>', (_) => done.future);
        final old = tester
            .widget<TutorialHtmlFallback>(find.byType(TutorialHtmlFallback))
            .onOpenLink;
        final pending = old('/#/docs/22');
        await reader(tester, '<p>新内容</p>', (_) async {
          throw StateError('navigation failed');
        });
        done.complete();
        expect(await pending, isFalse);
        final current = tester
            .widget<TutorialHtmlFallback>(find.byType(TutorialHtmlFallback))
            .onOpenLink;
        expect(await current('/#/docs/23'), isFalse);
        expect(launcher.urls, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }
}
