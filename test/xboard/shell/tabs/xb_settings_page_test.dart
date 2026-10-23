/// 形态 A 设置页单测：分组 + 全部选项齐全（复用 ToolsView 选项，原型风格）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/shell/tabs/mine/xb_settings_page.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/views/config/general.dart';
import 'package:fl_clash/l10n/l10n.dart';
import '../../../helpers/test_app.dart';
import 'package:fl_clash/providers/app.dart';

class _TestViewSize extends ViewSize {
  @override
  Size build() => const Size(1080, 3200);
}

void main() {
  for (final brand in ['brand_a', 'brand_b']) {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      testWidgets('$brand $platform opens one real general settings page', (
        tester,
      ) async {
        XboardConfig.bind(
          XboardConfig(
            subscribeUserAgent: 'flclash',
            devApiEndpoint: 'https://example.test',
            devSubscriptionEndpoint: 'https://example.test',
            debug: true,
            kIsTest: true,
            flavorId: brand,
            formA: true,
            appName: brand == 'brand_a' ? 'OmoFly' : '袋鼠加速',
          ),
        );
        addTearDown(XboardConfig.resetForTest);
        tester.view.physicalSize = const Size(1080, 3200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          TestApp(
            wrapInProviderScope: true,
            locale: const Locale('zh', 'CN'),
            overrides: [
              isMobileViewProvider.overrideWith(
                (ref) => platform == TargetPlatform.android,
              ),
              viewSizeProvider.overrideWith(_TestViewSize.new),
            ],
            child: const XbSettingsPage(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('通用设置'), findsOneWidget);
        expect(find.text('基本配置'), findsNothing);
        expect(find.text('应用程序'), findsNothing);
        await tester.tap(find.text('通用设置'));
        await tester.pumpAndSettle();
        expect(find.byType(GeneralView), findsOneWidget);
        expect(
          find.text(AppLocalizations.current.startupAndBackground),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));
    }
  }

  testWidgets('设置页渲染：更多/设置两组 + 全部选项（其他组/语言已隐藏）', (tester) async {
    // 设置列表较长，拉高测试视口让全部项一屏内 build（避免 ListView 懒加载漏项）。
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: XbSettingsPage())),
    );
    await tester.pump();

    // 分组标题：更多 / 设置（「其他」组用户 2026-06-29 全平台隐藏）。
    expect(find.text('设置'), findsWidgets); // AppBar 标题 + 分组
    expect(find.text('更多'), findsOneWidget);
    // 「其他」组（免责声明 / 关于）已隐藏。
    expect(find.text('其他'), findsNothing);
    expect(find.text('免责声明'), findsNothing);
    expect(find.text('关于'), findsNothing);

    expect(find.text('基本配置'), findsNothing);
    expect(find.text('应用程序'), findsNothing);

    // 选项（复用 ToolsView 全部能力，文案对齐原型/FlClash；语言默认隐藏强制简中）。
    for (final label in const [
      '主题',
      '备份与恢复',
      '通用设置',
      '进阶配置',
      '请求',
      '连接',
      '资源',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '缺选项: $label');
    }
  });
}
