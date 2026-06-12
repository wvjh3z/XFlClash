/// 更新弹窗 golden 核对（初始态：普通可关 / 强制不可关）。
///
/// 只覆盖静态确定态。下载中（spinner + 进度动画）/ 失败态（需触发网络）不进 golden
/// （循环动画 + 网络不确定性，违反 golden 像素确定性原则）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show AppUpdateModel, AppDownload;

import 'package:fl_clash/xboard/pages/xb_about_page.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/widgets/xb_update_dialog.dart';

const _cjkFontPaths = [
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/System/Library/Fonts/PingFang.ttc',
];

Future<void> _loadCjkFont() async {
  for (final path in _cjkFontPaths) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final bytes = await f.readAsBytes();
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return;
    } catch (_) {}
  }
}

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
  setUpAll(_loadCjkFont);

  Future<void> pumpDialog(WidgetTester tester, {required bool force}) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showXbUpdateDialog(context, _model(force: force)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('更新弹窗（普通 · 以后再说+立即更新）golden', (t) async {
    await pumpDialog(t, force: false);
    expect(t.takeException(), isNull);
    expect(find.text('🎉 发现新版本'), findsOneWidget);
    expect(find.text('以后再说'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    await expectLater(find.byType(AlertDialog),
        matchesGoldenFile('goldens/update_dialog_normal.png'));
  });

  testWidgets('更新弹窗（强制 · 仅立即更新 + 强制提示）golden', (t) async {
    await pumpDialog(t, force: true);
    expect(t.takeException(), isNull);
    expect(find.text('🎉 发现新版本'), findsOneWidget);
    expect(find.text('以后再说'), findsNothing);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.text('此为重要更新，必须更新后使用'), findsOneWidget);
    await expectLater(find.byType(AlertDialog),
        matchesGoldenFile('goldens/update_dialog_force.png'));
  });

  testWidgets('关于页（无更新）golden', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: XbAboutPage(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('检查更新'), findsOneWidget);
    await expectLater(find.byType(XbAboutPage),
        matchesGoldenFile('goldens/about_page_no_update.png'));
  });

  testWidgets('关于页（有更新 → 显示 pill）golden', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          availableUpdateProvider.overrideWith(() => _FakeUpdate()),
        ],
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: XbAboutPage(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('🎉 有新版本啦'), findsOneWidget);
    await expectLater(find.byType(XbAboutPage),
        matchesGoldenFile('goldens/about_page_has_update.png'));
  });
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
