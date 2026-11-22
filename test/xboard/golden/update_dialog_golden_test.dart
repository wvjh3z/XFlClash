/// 更新弹窗 golden 核对（初始态：普通可关 / 强制不可关）。
///
/// 只覆盖静态确定态。下载中（spinner + 进度动画）/ 失败态（需触发网络）不进 golden
/// （循环动画 + 网络不确定性，违反 golden 像素确定性原则）。
library;

import 'golden_environment.dart';
import 'shell_fixture.dart';
import 'package:fl_clash/enum/enum.dart' show CoreStatus;
import 'package:fl_clash/xboard/shell/tabs/home/home_tab.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show AppUpdateModel, AppDownload;

import 'package:fl_clash/xboard/pages/xb_about_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';

AppUpdateModel _model({required bool force}) => AppUpdateModel(
      versionCode: 116,
      versionName: '0.0.2',
      region: 'cn',
      downloads: const [
        AppDownload(
            url: 'https://dl.example.com/MyClient-0.0.2-android-arm64-v8a.apk',
            region: 'cn'),
      ],
      sha256: 'abc123',
      changelog: '1. 新增版本更新检查功能\n2. 首页右上角更新提示\n3. 优化连接稳定性',
      force: force,
    );

void main() {
  setUpAll(loadGoldenFonts);

  Future<void> pumpDialog(WidgetTester tester, {required bool force}) async {
    await pumpShell(tester, core: CoreStatus.connected, mobile:true, size:const Size(390,844));
    showXbUpdateDialog(tester.element(find.byType(HomeTab)), _model(force: force));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('更新弹窗（普通 · 以后再说+立即更新）golden', (t) async {
    await pumpDialog(t, force: false);
    expect(t.takeException(), isNull);
    // 标题经 EmojiText（=RichText）渲染，find.text 默认不匹配 RichText → 加 findRichText。
    expect(find.text('🎉 发现新版本', findRichText: true), findsOneWidget);
    expect(find.text('以后再说'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/update_dialog_normal.png');
  });

  testWidgets('更新弹窗（强制 · 仅立即更新 + 强制提示）golden', (t) async {
    await pumpDialog(t, force: true);
    expect(t.takeException(), isNull);
    expect(find.text('🎉 发现新版本', findRichText: true), findsOneWidget);
    expect(find.text('以后再说'), findsNothing);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.text('此为重要更新，必须更新后使用'), findsOneWidget);
    await expectXbGolden(t, find.byKey(const ValueKey('home-golden-window')), 'goldens/update_dialog_force.png');
  });

  for (final hasUpdate in [false, true]) {
    testWidgets('关于页（${hasUpdate ? '有更新' : '无更新'}）golden', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(ProviderScope(
        overrides: [if (hasUpdate) availableUpdateProvider.overrideWith(() => _FakeUpdate())],
        child: MaterialApp(debugShowCheckedModeBanner: false,
          routes: {'/': (_) => const SizedBox(), '/about': (_) => const XbAboutPage()},
          initialRoute: '/about'),
      ));
      await t.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('🎉 有新版本啦', findRichText: true), hasUpdate ? findsOneWidget : findsNothing);
      await expectXbGolden(t, find.byType(XbAboutPage),
          'goldens/about_page_${hasUpdate ? 'has' : 'no'}_update.png');
    });
  }
}

/// 注入「有更新」状态的 fake notifier。
class _FakeUpdate extends AvailableUpdate {
  @override
  AppUpdateModel? build() => const AppUpdateModel(
        versionCode: 116,
        versionName: '0.0.2',
        region: 'cn',
        downloads: [
          AppDownload(url: 'https://dl.example.com/x.apk', region: 'cn'),
        ],
        sha256: 'abc123',
        changelog: '更新内容',
        force: false,
      );
}
