/// 教程正文交给浏览器的回归。Widget test 不模拟 DOM、字体或浏览器剪贴板。
///
/// 旧 flutter_html 的 RichText 对比度/emoji/OutlinedButton 断言已不适用于
/// 原生 WebView；本文验证深浅主题下页面都传递完整正文且不追加文章标题。
/// HTML 准备与导航/复制规则由 util 专项测试验证，浏览器效果需平台验收。
library;

import 'package:fl_clash/xboard/models/xb_tutorial.dart';
import 'package:fl_clash/xboard/pages/tutorial_detail_page.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/tutorial_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

const _body = '''
<!doctype html>
<html><head>
  <title>服务端原有标题</title>
  <style>
    :root { --muted: #6b7280; }
    .apple-card { display: flex; gap: 12px; }
    @media (max-width: 600px) { .apple-card { flex-direction: column; } }
  </style>
</head><body>
  <h1>教程正文原有标题</h1>
  <div style="background:#fff3cd;color:#856404">⚠️ 有效订阅用户</div>
  <div class="apple-card"><span style="color:var(--muted)">2026 · 第 1 步</span></div>
  <img src="/images/step.png" alt="步骤图片">
</body></html>
''';

class _Auth extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.authenticated;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('教程详情 ${brightness.name}：保留网页样式，不增加正文标题', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final inputs = <TutorialReaderContent>[];
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(_Auth.new),
          tutorialDetailProvider(21).overrideWith(
            (ref) async => XbTutorialDetail(
              id: 21,
              title: '不应重复插入的后台文章标题',
              body: _body,
              updatedAt: DateTime(2026, 10, 14),
            ),
          ),
          tutorialReaderBuilderProvider.overrideWithValue((context, content) {
            inputs.add(content);
            return const SizedBox.expand(key: Key('native-reader-placeholder'));
          }),
        ],
      );
      container
          .read(apiEndpointProvider.notifier)
          .set('https://tutorials.example.invalid');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: brightness),
            home: const TutorialDetailPage(id: 21),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('native-reader-placeholder')),
        findsOneWidget,
      );
      expect(inputs, isNotEmpty);
      final document = html.parse(inputs.last.html);
      expect(document.head?.querySelector('title')?.text, '服务端原有标题');
      final styles = document
          .querySelectorAll('style')
          .map((e) => e.text)
          .join();
      expect(styles, contains('display: flex'));
      expect(styles, contains('@media'));
      expect(styles, contains('--muted'));
      expect(document.querySelectorAll('h1'), hasLength(1));
      expect(document.querySelector('h1')?.text, '教程正文原有标题');
      expect(
        document.querySelector('img')?.attributes['src'],
        'https://tutorials.example.invalid/images/step.png',
      );
      expect(inputs.last.resourceBase.host, 'tutorials.example.invalid');
      expect(find.text('不应重复插入的后台文章标题'), findsNothing);
      expect(find.text('教程正文原有标题'), findsNothing);
      expect(find.text('教程详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
